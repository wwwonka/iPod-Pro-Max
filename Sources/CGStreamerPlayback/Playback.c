#include "CGStreamerPlayback.h"
#include <gst/gst.h>
struct IPPMAudio { GstElement *player; guint watch; IPPMAudioEvent event; void *context; };
static gboolean receive(GstBus *bus, GstMessage *message, gpointer data) {
    IPPMAudio *audio = data;
    if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS) audio->event(audio->context, 1, NULL);
    if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
        GError *error = NULL;
        gst_message_parse_error(message, &error, NULL);
        audio->event(audio->context, 2, error ? error->message : "Audio playback failed.");
        if (error) g_error_free(error);
    }
    return TRUE;
}
IPPMAudio *ippm_audio_create(IPPMAudioEvent event, void *context) {
    if (!gst_init_check(NULL, NULL, NULL)) return NULL;
    GstElement *player = gst_element_factory_make("playbin", NULL);
    if (!player) return NULL;
    IPPMAudio *audio = g_new0(IPPMAudio, 1);
    audio->player = player; audio->event = event; audio->context = context;
    GstBus *bus = gst_element_get_bus(player);
    audio->watch = gst_bus_add_watch(bus, receive, audio);
    gst_object_unref(bus);
    return audio;
}
void ippm_audio_destroy(IPPMAudio *a) { gst_element_set_state(a->player, GST_STATE_NULL); g_source_remove(a->watch); gst_object_unref(a->player); g_free(a); }
void ippm_audio_load(IPPMAudio *a, const char *uri) { gst_element_set_state(a->player, GST_STATE_NULL); g_object_set(a->player, "uri", uri, NULL); }
void ippm_audio_play(IPPMAudio *a) { gst_element_set_state(a->player, GST_STATE_PLAYING); }
void ippm_audio_pause(IPPMAudio *a) { gst_element_set_state(a->player, GST_STATE_PAUSED); }
void ippm_audio_stop(IPPMAudio *a) { gst_element_set_state(a->player, GST_STATE_NULL); }
void ippm_audio_seek(IPPMAudio *a, double s) { gst_element_seek_simple(a->player, GST_FORMAT_TIME, GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT, (gint64)(s * GST_SECOND)); }
void ippm_audio_volume(IPPMAudio *a, double v) { g_object_set(a->player, "volume", v, NULL); }
double ippm_audio_position(IPPMAudio *a) { gint64 n = 0; gst_element_query_position(a->player, GST_FORMAT_TIME, &n); return (double)n / GST_SECOND; }
double ippm_audio_duration(IPPMAudio *a) { gint64 n = 0; gst_element_query_duration(a->player, GST_FORMAT_TIME, &n); return (double)n / GST_SECOND; }
