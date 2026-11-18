#ifndef CSOCKETS_H
#define CSOCKETS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int64_t csock_fd_t;
#define CSOCK_INVALID_FD ((csock_fd_t)-1)

enum {
    CSOCK_OK = 0,
    CSOCK_ERR_CLOSED = -1,
    CSOCK_ERR_CANCELLED = -2,
    CSOCK_ERR_TIMEOUT = -3,
    CSOCK_ERR_DNS = -4,
    CSOCK_ERR_IO = -5,
    CSOCK_ERR_ADDR_IN_USE = -6
};

typedef struct CSockReactor CSockReactor;

typedef void (*csock_connect_cb)(void *ctx, csock_fd_t fd, int32_t err, int32_t sys_err);
typedef void (*csock_accept_cb)(void *ctx, csock_fd_t client_fd, int32_t err, int32_t sys_err);
typedef void (*csock_read_cb)(void *ctx, const uint8_t *data, int32_t len, int32_t err, int32_t sys_err);
typedef void (*csock_write_cb)(void *ctx, int32_t written, int32_t err, int32_t sys_err);

CSockReactor *csock_reactor_create(void);
void csock_reactor_destroy(CSockReactor *reactor);

/// Connects a non-blocking TCP socket to `host:port` using the reactor's poll/WSAPoll thread.
/// DNS resolution (if `host` is not a numeric IP) runs off the reactor thread so poll never stalls.
uint64_t csock_connect_async(
    CSockReactor *reactor,
    const char *host,
    uint16_t port,
    int32_t timeout_ms,
    void *ctx,
    csock_connect_cb cb
);

/// Binds and listens on `0.0.0.0:port`. Returns CSOCK_INVALID_FD on error (`err_out` receives CSOCK_ERR_*).
csock_fd_t csock_listen(
    uint16_t port,
    int32_t backlog,
    uint16_t *actual_port_out,
    int32_t *err_out,
    int32_t *sys_err_out
);

uint64_t csock_accept_async(
    CSockReactor *reactor,
    csock_fd_t listen_fd,
    int32_t timeout_ms,
    void *ctx,
    csock_accept_cb cb
);

uint64_t csock_read_async(
    CSockReactor *reactor,
    csock_fd_t fd,
    size_t max_bytes,
    int32_t timeout_ms,
    void *ctx,
    csock_read_cb cb
);

/// Writes `len` bytes sequentially from `bytes` (which must remain valid until callback fires, or copied by caller).
uint64_t csock_write_async(
    CSockReactor *reactor,
    csock_fd_t fd,
    const uint8_t *bytes,
    size_t len,
    int32_t timeout_ms,
    void *ctx,
    csock_write_cb cb
);

void csock_cancel_op(CSockReactor *reactor, uint64_t op_id);
void csock_close_fd(CSockReactor *reactor, csock_fd_t fd);

#ifdef __cplusplus
}
#endif

#endif /* CSOCKETS_H */
