#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#else
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#endif

#include "CSockets.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
typedef SOCKET raw_sock_t;
#define RAW_INVALID_SOCK INVALID_SOCKET
typedef CRITICAL_SECTION csock_mutex_t;
typedef CONDITION_VARIABLE csock_cond_t;
static void mutex_init(csock_mutex_t *m) { InitializeCriticalSection(m); }
static void mutex_destroy(csock_mutex_t *m) { DeleteCriticalSection(m); }
static void mutex_lock(csock_mutex_t *m) { EnterCriticalSection(m); }
static void mutex_unlock(csock_mutex_t *m) { LeaveCriticalSection(m); }
static void cond_init(csock_cond_t *c) { InitializeConditionVariable(c); }
static void cond_destroy(csock_cond_t *c) { (void)c; }
static void cond_wait(csock_cond_t *c, csock_mutex_t *m) { SleepConditionVariableCS(c, m, INFINITE); }
static void cond_broadcast(csock_cond_t *c) { WakeAllConditionVariable(c); }
static int last_sock_err(void) { return WSAGetLastError(); }
static void close_raw_sock(raw_sock_t s) { if (s != INVALID_SOCKET) closesocket(s); }
static int set_nonblocking(raw_sock_t s) {
    u_long mode = 1;
    return ioctlsocket(s, FIONBIO, &mode);
}
static int is_would_block(int e) { return e == WSAEWOULDBLOCK || e == WSAEINPROGRESS; }
static int is_addr_in_use(int e) { return e == WSAEADDRINUSE; }
static int64_t monotonic_ms(void) { return (int64_t)GetTickCount64(); }
#else
typedef int raw_sock_t;
#define RAW_INVALID_SOCK (-1)
typedef pthread_mutex_t csock_mutex_t;
typedef pthread_cond_t csock_cond_t;
static void mutex_init(csock_mutex_t *m) { pthread_mutex_init(m, NULL); }
static void mutex_destroy(csock_mutex_t *m) { pthread_mutex_destroy(m); }
static void mutex_lock(csock_mutex_t *m) { pthread_mutex_lock(m); }
static void mutex_unlock(csock_mutex_t *m) { pthread_mutex_unlock(m); }
static void cond_init(csock_cond_t *c) { pthread_cond_init(c, NULL); }
static void cond_destroy(csock_cond_t *c) { pthread_cond_destroy(c); }
static void cond_wait(csock_cond_t *c, csock_mutex_t *m) { pthread_cond_wait(c, m); }
static void cond_broadcast(csock_cond_t *c) { pthread_cond_broadcast(c); }
static int last_sock_err(void) { return errno; }
static void close_raw_sock(raw_sock_t s) { if (s >= 0) close(s); }
static int set_nonblocking(raw_sock_t s) {
    int flags = fcntl(s, F_GETFL, 0);
    if (flags < 0) return -1;
    if (fcntl(s, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
    fcntl(s, F_SETFD, FD_CLOEXEC);
#ifdef SO_NOSIGPIPE
    int yes = 1;
    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
    return 0;
}
static int is_would_block(int e) { return e == EWOULDBLOCK || e == EAGAIN || e == EINPROGRESS; }
static int is_addr_in_use(int e) { return e == EADDRINUSE; }
static int64_t monotonic_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000LL + (int64_t)(ts.tv_nsec / 1000000LL);
}
#endif

typedef enum {
    OP_CONNECT = 1,
    OP_ACCEPT = 2,
    OP_READ = 3,
    OP_WRITE = 4
} OpKind;

typedef struct PendingOp {
    uint64_t id;
    OpKind kind;
    raw_sock_t fd;
    int64_t deadline_ms; /* 0 = no timeout */
    void *ctx;
    union {
        csock_connect_cb connect_cb;
        csock_accept_cb accept_cb;
        csock_read_cb read_cb;
        csock_write_cb write_cb;
    } cb;
    size_t max_bytes;
    uint8_t *write_buf;
    size_t write_len;
    size_t write_pos;
    int dns_pending;
    struct PendingOp *next;
} PendingOp;

struct CSockReactor {
    csock_mutex_t lock;
    csock_cond_t dns_cond;
    int active_dns;
    PendingOp *ops;
    uint64_t next_id;
    int stopping;
#if defined(_WIN32)
    raw_sock_t wake_read;
    raw_sock_t wake_write;
    HANDLE thread;
    int thread_running;
#else
    int wake_fds[2];
    pthread_t thread;
    int thread_running;
#endif
};

static void wake_reactor(CSockReactor *r) {
    uint8_t b = 1;
#if defined(_WIN32)
    if (r->wake_write != INVALID_SOCKET) {
        send(r->wake_write, (const char *)&b, 1, 0);
    }
#else
    if (r->wake_fds[1] >= 0) {
        ssize_t ignored = write(r->wake_fds[1], &b, 1);
        (void)ignored;
    }
#endif
}

static void drain_wake(CSockReactor *r) {
    uint8_t buf[64];
#if defined(_WIN32)
    while (recv(r->wake_read, (char *)buf, sizeof(buf), 0) > 0) {}
#else
    while (read(r->wake_fds[0], buf, sizeof(buf)) > 0) {}
#endif
}

static void fire_and_free_op(PendingOp *op, int32_t err, int32_t sys_err, const uint8_t *read_data, int32_t read_len, csock_fd_t extra_fd) {
    switch (op->kind) {
    case OP_CONNECT:
        if (op->cb.connect_cb) {
            op->cb.connect_cb(op->ctx, extra_fd, err, sys_err);
        }
        break;
    case OP_ACCEPT:
        if (op->cb.accept_cb) {
            op->cb.accept_cb(op->ctx, extra_fd, err, sys_err);
        }
        break;
    case OP_READ:
        if (op->cb.read_cb) {
            op->cb.read_cb(op->ctx, read_data, read_len, err, sys_err);
        }
        break;
    case OP_WRITE:
        if (op->cb.write_cb) {
            op->cb.write_cb(op->ctx, (int32_t)op->write_pos, err, sys_err);
        }
        free(op->write_buf);
        break;
    }
    free(op);
}

static void reactor_loop(CSockReactor *r) {
    for (;;) {
        mutex_lock(&r->lock);
        if (r->stopping) {
            PendingOp *cur = r->ops;
            r->ops = NULL;
            mutex_unlock(&r->lock);
            while (cur) {
                PendingOp *nxt = cur->next;
                if (cur->kind == OP_CONNECT && cur->fd != RAW_INVALID_SOCK) {
                    close_raw_sock(cur->fd);
                }
                fire_and_free_op(cur, CSOCK_ERR_CANCELLED, 0, NULL, 0, CSOCK_INVALID_FD);
                cur = nxt;
            }
            return;
        }

        int64_t now = monotonic_ms();
        size_t op_count = 0;
        int32_t timeout_ms = -1;

        for (PendingOp *cur = r->ops; cur; cur = cur->next) {
            if (!cur->dns_pending && cur->fd != RAW_INVALID_SOCK) {
                op_count++;
            }
            if (cur->deadline_ms > 0) {
                int64_t rem = cur->deadline_ms - now;
                if (rem <= 0) {
                    timeout_ms = 0;
                } else if (timeout_ms < 0 || rem < timeout_ms) {
                    timeout_ms = rem > 0x7fffffffLL ? 0x7fffffff : (int32_t)rem;
                }
            }
        }

        size_t nfds = 1 + op_count;
#if defined(_WIN32)
        WSAPOLLFD *pfds = (WSAPOLLFD *)calloc(nfds, sizeof(WSAPOLLFD));
        PendingOp **mapped = op_count ? (PendingOp **)calloc(op_count, sizeof(PendingOp *)) : NULL;
        pfds[0].fd = r->wake_read;
        pfds[0].events = POLLRDNORM;
#else
        struct pollfd *pfds = (struct pollfd *)calloc(nfds, sizeof(struct pollfd));
        PendingOp **mapped = op_count ? (PendingOp **)calloc(op_count, sizeof(PendingOp *)) : NULL;
        pfds[0].fd = r->wake_fds[0];
        pfds[0].events = POLLIN;
#endif
        size_t idx = 0;
        for (PendingOp *cur = r->ops; cur; cur = cur->next) {
            if (cur->dns_pending || cur->fd == RAW_INVALID_SOCK) continue;
            mapped[idx] = cur;
            pfds[1 + idx].fd = cur->fd;
#if defined(_WIN32)
            pfds[1 + idx].events = (cur->kind == OP_CONNECT || cur->kind == OP_WRITE) ? POLLWRNORM : POLLRDNORM;
#else
            pfds[1 + idx].events = (cur->kind == OP_CONNECT || cur->kind == OP_WRITE) ? POLLOUT : POLLIN;
#endif
            idx++;
        }
        mutex_unlock(&r->lock);

#if defined(_WIN32)
        int pr = WSAPoll(pfds, (ULONG)nfds, timeout_ms);
#else
        int pr = poll(pfds, (nfds_t)nfds, timeout_ms);
#endif
        (void)pr;

        if (pfds[0].revents != 0) {
            drain_wake(r);
        }

        /* Collect triggered or expired operations while keeping locks clean */
        now = monotonic_ms();
        mutex_lock(&r->lock);
        PendingOp *completed = NULL;
        PendingOp **prev_ptr = &r->ops;

        while (*prev_ptr) {
            PendingOp *cur = *prev_ptr;
            if (cur->dns_pending) {
                prev_ptr = &cur->next;
                continue;
            }

            short revents = 0;
            for (size_t i = 0; i < idx; i++) {
                if (mapped[i] == cur) {
                    revents = pfds[1 + i].revents;
                    break;
                }
            }

            int timed_out = (cur->deadline_ms > 0 && now >= cur->deadline_ms);
            int remove_now = 0;
            int32_t done_err = CSOCK_OK;
            int32_t done_sys = 0;
            csock_fd_t done_fd = CSOCK_INVALID_FD;
            uint8_t *done_read_buf = NULL;
            int32_t done_read_len = 0;

            if (revents != 0) {
                if (cur->kind == OP_CONNECT) {
                    int so_err = 0;
                    socklen_t len = sizeof(so_err);
                    if (getsockopt(cur->fd, SOL_SOCKET, SO_ERROR, (char *)&so_err, &len) < 0) {
                        so_err = last_sock_err();
                    }
                    if (so_err == 0 && !(revents & POLLERR) && !(revents & POLLHUP)) {
                        done_fd = (csock_fd_t)cur->fd;
                        done_err = CSOCK_OK;
                        remove_now = 1;
                    } else if (so_err != 0 || (revents & POLLERR) || (revents & POLLHUP)) {
                        close_raw_sock(cur->fd);
                        cur->fd = RAW_INVALID_SOCK;
                        done_err = CSOCK_ERR_IO;
                        done_sys = so_err ? so_err : -1;
                        remove_now = 1;
                    }
                } else if (cur->kind == OP_ACCEPT) {
                    struct sockaddr_storage ss;
                    socklen_t slen = sizeof(ss);
                    raw_sock_t cfd = accept(cur->fd, (struct sockaddr *)&ss, &slen);
#if defined(_WIN32)
                    if (cfd != INVALID_SOCKET) {
#else
                    if (cfd >= 0) {
#endif
                        set_nonblocking(cfd);
                        done_fd = (csock_fd_t)cfd;
                        done_err = CSOCK_OK;
                        remove_now = 1;
                    } else {
                        int se = last_sock_err();
                        if (!is_would_block(se)) {
                            done_err = CSOCK_ERR_IO;
                            done_sys = se;
                            remove_now = 1;
                        }
                    }
                } else if (cur->kind == OP_READ) {
                    size_t cap = cur->max_bytes > 0 ? cur->max_bytes : 65536;
                    uint8_t *tmp = (uint8_t *)malloc(cap);
                    int rflags = 0;
#if defined(_WIN32)
                    int n = recv(cur->fd, (char *)tmp, (int)cap, rflags);
#else
                    ssize_t n = recv(cur->fd, tmp, cap, rflags);
#endif
                    if (n > 0) {
                        done_read_buf = tmp;
                        done_read_len = (int32_t)n;
                        done_err = CSOCK_OK;
                        remove_now = 1;
                    } else if (n == 0) {
                        free(tmp);
                        done_err = CSOCK_ERR_CLOSED;
                        remove_now = 1;
                    } else {
                        int se = last_sock_err();
                        free(tmp);
                        if (!is_would_block(se)) {
                            done_err = CSOCK_ERR_IO;
                            done_sys = se;
                            remove_now = 1;
                        }
                    }
                } else if (cur->kind == OP_WRITE) {
                    int sflags = 0;
#if !defined(_WIN32) && defined(MSG_NOSIGNAL)
                    sflags = MSG_NOSIGNAL;
#endif
                    while (cur->write_pos < cur->write_len) {
                        size_t rem = cur->write_len - cur->write_pos;
#if defined(_WIN32)
                        int chunk = rem > 65536 ? 65536 : (int)rem;
                        int n = send(cur->fd, (const char *)(cur->write_buf + cur->write_pos), chunk, sflags);
#else
                        ssize_t n = send(cur->fd, cur->write_buf + cur->write_pos, rem, sflags);
#endif
                        if (n > 0) {
                            cur->write_pos += (size_t)n;
                        } else if (n < 0) {
                            int se = last_sock_err();
                            if (is_would_block(se)) {
                                break;
                            }
                            done_err = CSOCK_ERR_IO;
                            done_sys = se;
                            remove_now = 1;
                            break;
                        } else {
                            done_err = CSOCK_ERR_CLOSED;
                            remove_now = 1;
                            break;
                        }
                    }
                    if (!remove_now && cur->write_pos >= cur->write_len) {
                        done_err = CSOCK_OK;
                        remove_now = 1;
                    }
                }
            }

            if (!remove_now && timed_out) {
                if (cur->kind == OP_CONNECT && cur->fd != RAW_INVALID_SOCK) {
                    close_raw_sock(cur->fd);
                    cur->fd = RAW_INVALID_SOCK;
                }
                done_err = CSOCK_ERR_TIMEOUT;
                remove_now = 1;
            }

            if (remove_now) {
                *prev_ptr = cur->next;
                /* Stash result for invocation after unlock */
                cur->next = completed;
                cur->dns_pending = done_err;
                cur->deadline_ms = (int64_t)done_sys;
                if (cur->kind == OP_READ) {
                    cur->write_buf = done_read_buf;
                    cur->write_len = (size_t)done_read_len;
                } else if (cur->kind == OP_CONNECT || cur->kind == OP_ACCEPT) {
                    cur->fd = (raw_sock_t)done_fd;
                }
                completed = cur;
            } else {
                prev_ptr = &cur->next;
            }
        }
        mutex_unlock(&r->lock);

        free(pfds);
        free(mapped);

        while (completed) {
            PendingOp *cur = completed;
            completed = cur->next;
            int32_t err = (int32_t)cur->dns_pending;
            int32_t sys_err = (int32_t)cur->deadline_ms;
            if (cur->kind == OP_READ) {
                uint8_t *rbuf = cur->write_buf;
                int32_t rlen = (int32_t)cur->write_len;
                cur->write_buf = NULL;
                fire_and_free_op(cur, err, sys_err, rbuf, rlen, CSOCK_INVALID_FD);
                free(rbuf);
            } else if (cur->kind == OP_CONNECT || cur->kind == OP_ACCEPT) {
                csock_fd_t out_fd = (err == CSOCK_OK) ? (csock_fd_t)cur->fd : CSOCK_INVALID_FD;
                fire_and_free_op(cur, err, sys_err, NULL, 0, out_fd);
            } else {
                fire_and_free_op(cur, err, sys_err, NULL, 0, CSOCK_INVALID_FD);
            }
        }
    }
}

#if defined(_WIN32)
static DWORD WINAPI reactor_thread_entry(LPVOID arg) {
    reactor_loop((CSockReactor *)arg);
    return 0;
}
#else
static void *reactor_thread_entry(void *arg) {
    reactor_loop((CSockReactor *)arg);
    return NULL;
}
#endif

CSockReactor *csock_reactor_create(void) {
#if defined(_WIN32)
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        return NULL;
    }
#else
    signal(SIGPIPE, SIG_IGN);
#endif
    CSockReactor *r = (CSockReactor *)calloc(1, sizeof(CSockReactor));
    if (!r) return NULL;
    mutex_init(&r->lock);
    cond_init(&r->dns_cond);
    r->next_id = 1;

#if defined(_WIN32)
    r->wake_read = INVALID_SOCKET;
    r->wake_write = INVALID_SOCKET;
    raw_sock_t listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listener == INVALID_SOCKET) { csock_reactor_destroy(r); return NULL; }
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(listener, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(listener, 1) != 0) {
        closesocket(listener);
        csock_reactor_destroy(r);
        return NULL;
    }
    int alen = sizeof(addr);
    getsockname(listener, (struct sockaddr *)&addr, &alen);
    r->wake_write = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (r->wake_write == INVALID_SOCKET || connect(r->wake_write, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        closesocket(listener);
        csock_reactor_destroy(r);
        return NULL;
    }
    r->wake_read = accept(listener, NULL, NULL);
    closesocket(listener);
    if (r->wake_read == INVALID_SOCKET) { csock_reactor_destroy(r); return NULL; }
    set_nonblocking(r->wake_read);
    set_nonblocking(r->wake_write);
    r->thread = CreateThread(NULL, 0, reactor_thread_entry, r, 0, NULL);
    r->thread_running = (r->thread != NULL);
#else
    r->wake_fds[0] = -1;
    r->wake_fds[1] = -1;
    if (pipe(r->wake_fds) != 0) {
        csock_reactor_destroy(r);
        return NULL;
    }
    set_nonblocking(r->wake_fds[0]);
    set_nonblocking(r->wake_fds[1]);
    if (pthread_create(&r->thread, NULL, reactor_thread_entry, r) == 0) {
        r->thread_running = 1;
    }
#endif
    return r;
}

void csock_reactor_destroy(CSockReactor *r) {
    if (!r) return;
    mutex_lock(&r->lock);
    r->stopping = 1;
    while (r->active_dns > 0) {
        cond_wait(&r->dns_cond, &r->lock);
    }
    mutex_unlock(&r->lock);
    if (r->thread_running) {
        wake_reactor(r);
#if defined(_WIN32)
        WaitForSingleObject(r->thread, INFINITE);
        CloseHandle(r->thread);
#else
        pthread_join(r->thread, NULL);
#endif
        r->thread_running = 0;
    }
#if defined(_WIN32)
    close_raw_sock(r->wake_read);
    close_raw_sock(r->wake_write);
    WSACleanup();
#else
    if (r->wake_fds[0] >= 0) close(r->wake_fds[0]);
    if (r->wake_fds[1] >= 0) close(r->wake_fds[1]);
#endif
    cond_destroy(&r->dns_cond);
    mutex_destroy(&r->lock);
    free(r);
}

typedef struct {
    CSockReactor *reactor;
    uint64_t op_id;
    char *host;
    uint16_t port;
    int32_t timeout_ms;
} ConnectArgs;

static void dns_done(CSockReactor *r) {
    mutex_lock(&r->lock);
    r->active_dns--;
    if (r->active_dns == 0) {
        cond_broadcast(&r->dns_cond);
    }
    mutex_unlock(&r->lock);
}

static void perform_dns_and_begin_connect(ConnectArgs *args) {
    CSockReactor *r = args->reactor;
    uint64_t op_id = args->op_id;
    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%u", (unsigned)args->port);

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    struct addrinfo *res = NULL;
    int gai = getaddrinfo(args->host, port_str, &hints, &res);

    mutex_lock(&r->lock);
    PendingOp *op = NULL;
    PendingOp **prev = &r->ops;
    while (*prev) {
        if ((*prev)->id == op_id) {
            op = *prev;
            break;
        }
        prev = &(*prev)->next;
    }
    if (!op || r->stopping) {
        mutex_unlock(&r->lock);
        if (res) freeaddrinfo(res);
        free(args->host);
        free(args);
        dns_done(r);
        return;
    }

    if (gai != 0 || !res) {
        *prev = op->next;
        mutex_unlock(&r->lock);
        fire_and_free_op(op, CSOCK_ERR_DNS, gai, NULL, 0, CSOCK_INVALID_FD);
        free(args->host);
        free(args);
        dns_done(r);
        return;
    }

    raw_sock_t sock = RAW_INVALID_SOCK;
    int last_err = 0;
    int connected_immediately = 0;
    for (struct addrinfo *p = res; p; p = p->ai_next) {
        raw_sock_t s = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (s == RAW_INVALID_SOCK) continue;
        set_nonblocking(s);
        int rc = connect(s, p->ai_addr, (socklen_t)p->ai_addrlen);
        if (rc == 0) {
            sock = s;
            connected_immediately = 1;
            break;
        }
        int se = last_sock_err();
        if (is_would_block(se)) {
            sock = s;
            break;
        }
        last_err = se;
        close_raw_sock(s);
    }
    freeaddrinfo(res);

    if (sock == RAW_INVALID_SOCK) {
        *prev = op->next;
        mutex_unlock(&r->lock);
        fire_and_free_op(op, CSOCK_ERR_IO, last_err, NULL, 0, CSOCK_INVALID_FD);
        free(args->host);
        free(args);
        dns_done(r);
        return;
    }

    if (connected_immediately) {
        *prev = op->next;
        mutex_unlock(&r->lock);
        fire_and_free_op(op, CSOCK_OK, 0, NULL, 0, (csock_fd_t)sock);
        free(args->host);
        free(args);
        dns_done(r);
        return;
    }

    op->fd = sock;
    op->dns_pending = 0;
    if (args->timeout_ms > 0) {
        op->deadline_ms = monotonic_ms() + args->timeout_ms;
    }
    mutex_unlock(&r->lock);
    wake_reactor(r);

    free(args->host);
    free(args);
    dns_done(r);
}

#if defined(_WIN32)
static DWORD WINAPI dns_worker_entry(LPVOID arg) {
    perform_dns_and_begin_connect((ConnectArgs *)arg);
    return 0;
}
#else
static void *dns_worker_entry(void *arg) {
    perform_dns_and_begin_connect((ConnectArgs *)arg);
    return NULL;
}
#endif

uint64_t csock_connect_async(
    CSockReactor *r,
    const char *host,
    uint16_t port,
    int32_t timeout_ms,
    void *ctx,
    csock_connect_cb cb
) {
    if (!r || !host) return 0;
    PendingOp *op = (PendingOp *)calloc(1, sizeof(PendingOp));
    op->kind = OP_CONNECT;
    op->fd = RAW_INVALID_SOCK;
    op->dns_pending = 1;
    op->ctx = ctx;
    op->cb.connect_cb = cb;
    op->deadline_ms = timeout_ms > 0 ? monotonic_ms() + timeout_ms : 0;

    mutex_lock(&r->lock);
    uint64_t id = r->next_id++;
    op->id = id;
    op->next = r->ops;
    r->ops = op;
    r->active_dns++;
    mutex_unlock(&r->lock);

    ConnectArgs *args = (ConnectArgs *)calloc(1, sizeof(ConnectArgs));
    args->reactor = r;
    args->op_id = id;
    size_t hlen = strlen(host);
    args->host = (char *)malloc(hlen + 1);
    memcpy(args->host, host, hlen + 1);
    args->port = port;
    args->timeout_ms = timeout_ms;

#if defined(_WIN32)
    HANDLE th = CreateThread(NULL, 0, dns_worker_entry, args, 0, NULL);
    if (th) CloseHandle(th);
#else
    pthread_t th;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&th, &attr, dns_worker_entry, args);
    pthread_attr_destroy(&attr);
#endif
    return id;
}

csock_fd_t csock_listen(
    uint16_t port,
    int32_t backlog,
    uint16_t *actual_port_out,
    int32_t *err_out,
    int32_t *sys_err_out
) {
    raw_sock_t s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == RAW_INVALID_SOCK) {
        if (err_out) *err_out = CSOCK_ERR_IO;
        if (sys_err_out) *sys_err_out = last_sock_err();
        return CSOCK_INVALID_FD;
    }
    int yes = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (const char *)&yes, sizeof(yes));
    set_nonblocking(s);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);

    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(s, backlog > 0 ? backlog : 16) != 0) {
        int se = last_sock_err();
        close_raw_sock(s);
        if (err_out) *err_out = is_addr_in_use(se) ? CSOCK_ERR_ADDR_IN_USE : CSOCK_ERR_IO;
        if (sys_err_out) *sys_err_out = se;
        return CSOCK_INVALID_FD;
    }

    socklen_t len = sizeof(addr);
    if (getsockname(s, (struct sockaddr *)&addr, &len) == 0 && actual_port_out) {
        *actual_port_out = ntohs(addr.sin_port);
    }
    if (err_out) *err_out = CSOCK_OK;
    if (sys_err_out) *sys_err_out = 0;
    return (csock_fd_t)s;
}

static uint64_t enqueue_op(CSockReactor *r, PendingOp *op) {
    mutex_lock(&r->lock);
    uint64_t id = r->next_id++;
    op->id = id;
    op->next = r->ops;
    r->ops = op;
    mutex_unlock(&r->lock);
    wake_reactor(r);
    return id;
}

uint64_t csock_accept_async(
    CSockReactor *r,
    csock_fd_t listen_fd,
    int32_t timeout_ms,
    void *ctx,
    csock_accept_cb cb
) {
    if (!r || listen_fd == CSOCK_INVALID_FD) return 0;
    PendingOp *op = (PendingOp *)calloc(1, sizeof(PendingOp));
    op->kind = OP_ACCEPT;
    op->fd = (raw_sock_t)listen_fd;
    op->deadline_ms = timeout_ms > 0 ? monotonic_ms() + timeout_ms : 0;
    op->ctx = ctx;
    op->cb.accept_cb = cb;
    return enqueue_op(r, op);
}

uint64_t csock_read_async(
    CSockReactor *r,
    csock_fd_t fd,
    size_t max_bytes,
    int32_t timeout_ms,
    void *ctx,
    csock_read_cb cb
) {
    if (!r || fd == CSOCK_INVALID_FD) return 0;
    PendingOp *op = (PendingOp *)calloc(1, sizeof(PendingOp));
    op->kind = OP_READ;
    op->fd = (raw_sock_t)fd;
    op->max_bytes = max_bytes;
    op->deadline_ms = timeout_ms > 0 ? monotonic_ms() + timeout_ms : 0;
    op->ctx = ctx;
    op->cb.read_cb = cb;
    return enqueue_op(r, op);
}

uint64_t csock_write_async(
    CSockReactor *r,
    csock_fd_t fd,
    const uint8_t *bytes,
    size_t len,
    int32_t timeout_ms,
    void *ctx,
    csock_write_cb cb
) {
    if (!r || fd == CSOCK_INVALID_FD) return 0;
    PendingOp *op = (PendingOp *)calloc(1, sizeof(PendingOp));
    op->kind = OP_WRITE;
    op->fd = (raw_sock_t)fd;
    op->deadline_ms = timeout_ms > 0 ? monotonic_ms() + timeout_ms : 0;
    op->ctx = ctx;
    op->cb.write_cb = cb;
    op->write_len = len;
    if (len > 0 && bytes) {
        op->write_buf = (uint8_t *)malloc(len);
        memcpy(op->write_buf, bytes, len);
    }
    return enqueue_op(r, op);
}

void csock_cancel_op(CSockReactor *r, uint64_t op_id) {
    if (!r || op_id == 0) return;
    mutex_lock(&r->lock);
    PendingOp *found = NULL;
    PendingOp **prev = &r->ops;
    while (*prev) {
        if ((*prev)->id == op_id) {
            found = *prev;
            *prev = found->next;
            break;
        }
        prev = &(*prev)->next;
    }
    mutex_unlock(&r->lock);
    wake_reactor(r);
    if (found) {
        if (found->kind == OP_CONNECT && found->fd != RAW_INVALID_SOCK) {
            close_raw_sock(found->fd);
        }
        fire_and_free_op(found, CSOCK_ERR_CANCELLED, 0, NULL, 0, CSOCK_INVALID_FD);
    }
}

void csock_close_fd(CSockReactor *r, csock_fd_t fd) {
    if (fd == CSOCK_INVALID_FD) return;
    if (r) {
        mutex_lock(&r->lock);
        PendingOp *cancelled = NULL;
        PendingOp **prev = &r->ops;
        while (*prev) {
            if ((*prev)->fd == (raw_sock_t)fd) {
                PendingOp *cur = *prev;
                *prev = cur->next;
                cur->next = cancelled;
                cancelled = cur;
            } else {
                prev = &(*prev)->next;
            }
        }
        mutex_unlock(&r->lock);
        wake_reactor(r);
        while (cancelled) {
            PendingOp *cur = cancelled;
            cancelled = cur->next;
            fire_and_free_op(cur, CSOCK_ERR_CANCELLED, 0, NULL, 0, CSOCK_INVALID_FD);
        }
    }
    close_raw_sock((raw_sock_t)fd);
}
