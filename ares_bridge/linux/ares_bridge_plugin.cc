#include "include/ares_bridge/ares_bridge_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <cstring>

#define ARES_BRIDGE_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), ares_bridge_plugin_get_type(), \
                              AresBridgePlugin))

struct _AresBridgePlugin {
  GObject parent_instance;
  FlEventChannel* event_channel;
  gboolean has_listener;
  gboolean initialized;
  gchar* local_role;
};

G_DEFINE_TYPE(AresBridgePlugin, ares_bridge_plugin, g_object_get_type())

static gint64 timestamp_ms() {
  return g_get_real_time() / 1000;
}

static void map_set_string(FlValue* map, const gchar* key,
                           const gchar* value) {
  fl_value_set_string_take(map, key, fl_value_new_string(value));
}

static void map_set_bool(FlValue* map, const gchar* key, gboolean value) {
  fl_value_set_string_take(map, key, fl_value_new_bool(value));
}

static void emit_connection(AresBridgePlugin* self, const gchar* state,
                            const gchar* message = nullptr) {
  if (!self->has_listener || self->event_channel == nullptr) {
    return;
  }
  g_autoptr(FlValue) event = fl_value_new_map();
  map_set_string(event, "type", "connection");
  map_set_string(event, "state", state);
  map_set_string(event, "localRole", self->local_role);
  fl_value_set_string_take(event, "timestampMs",
                           fl_value_new_int(timestamp_ms()));
  if (message != nullptr) {
    map_set_string(event, "message", message);
  }
  fl_event_channel_send(self->event_channel, event, nullptr, nullptr);
}

static FlMethodResponse* capabilities_response() {
  g_autoptr(FlValue) capabilities = fl_value_new_map();
  map_set_string(capabilities, "platform", "linux");
  map_set_bool(capabilities, "isSupported", FALSE);
  map_set_bool(capabilities, "supportsUsbHost", TRUE);
  map_set_bool(capabilities, "supportsUsbAccessory", FALSE);
  map_set_bool(capabilities, "supportsBidirectionalTransfer", FALSE);
  map_set_string(
      capabilities, "reason",
      "The Linux AOA/libusb host transport has not been linked yet.");
  return FL_METHOD_RESPONSE(fl_method_success_response_new(capabilities));
}

static FlMethodResponse* error_response(const gchar* code,
                                        const gchar* message) {
  return FL_METHOD_RESPONSE(
      fl_method_error_response_new(code, message, nullptr));
}

static const gchar* configuration_role(FlMethodCall* method_call) {
  FlValue* arguments = fl_method_call_get_args(method_call);
  if (arguments == nullptr ||
      fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  FlValue* role = fl_value_lookup_string(arguments, "role");
  if (role == nullptr || fl_value_get_type(role) != FL_VALUE_TYPE_STRING) {
    return "automatic";
  }
  return fl_value_get_string(role);
}

static void ares_bridge_plugin_handle_method_call(
    AresBridgePlugin* self, FlMethodCall* method_call) {
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, "getCapabilities") == 0) {
    response = capabilities_response();
  } else if (strcmp(method, "initialize") == 0) {
    const gchar* role = configuration_role(method_call);
    if (role == nullptr) {
      response =
          error_response("invalid_argument",
                         "initialize expects a configuration map.");
    } else if (strcmp(role, "usbAccessory") == 0) {
      response = error_response(
          "unsupported_role",
          "Linux must be the USB host for Android Open Accessory.");
    } else {
      g_free(self->local_role);
      self->local_role = g_strdup("usbHost");
      self->initialized = TRUE;
      response =
          FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
  } else if (strcmp(method, "startListening") == 0) {
    if (!self->initialized) {
      response = error_response("not_initialized",
                                "Call initialize before startListening.");
    } else {
      emit_connection(self, "listening");
      const gchar* message =
          "The Linux AOA/libusb host transport has not been linked yet.";
      emit_connection(self, "failed", message);
      response = error_response("transport_unavailable", message);
    }
  } else if (strcmp(method, "stopListening") == 0 ||
             strcmp(method, "dispose") == 0) {
    emit_connection(self, "stopped");
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "sendFile") == 0 ||
             strcmp(method, "sendFiles") == 0) {
    response = error_response("not_connected", "No active Ares USB peer.");
  } else if (strcmp(method, "cancelTransfer") == 0) {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static FlMethodErrorResponse* event_listen_cb(FlEventChannel* channel,
                                              FlValue* arguments,
                                              gpointer user_data) {
  AresBridgePlugin* self = ARES_BRIDGE_PLUGIN(user_data);
  self->has_listener = TRUE;
  return nullptr;
}

static FlMethodErrorResponse* event_cancel_cb(FlEventChannel* channel,
                                              FlValue* arguments,
                                              gpointer user_data) {
  AresBridgePlugin* self = ARES_BRIDGE_PLUGIN(user_data);
  self->has_listener = FALSE;
  return nullptr;
}

static void ares_bridge_plugin_dispose(GObject* object) {
  AresBridgePlugin* self = ARES_BRIDGE_PLUGIN(object);
  g_clear_object(&self->event_channel);
  g_clear_pointer(&self->local_role, g_free);
  G_OBJECT_CLASS(ares_bridge_plugin_parent_class)->dispose(object);
}

static void ares_bridge_plugin_class_init(AresBridgePluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = ares_bridge_plugin_dispose;
}

static void ares_bridge_plugin_init(AresBridgePlugin* self) {
  self->event_channel = nullptr;
  self->has_listener = FALSE;
  self->initialized = FALSE;
  self->local_role = g_strdup("usbHost");
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  AresBridgePlugin* plugin = ARES_BRIDGE_PLUGIN(user_data);
  ares_bridge_plugin_handle_method_call(plugin, method_call);
}

void ares_bridge_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  AresBridgePlugin* plugin = ARES_BRIDGE_PLUGIN(
      g_object_new(ares_bridge_plugin_get_type(), nullptr));
  FlBinaryMessenger* messenger =
      fl_plugin_registrar_get_messenger(registrar);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) method_channel =
      fl_method_channel_new(messenger, "ares_bridge/methods",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      method_channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  plugin->event_channel = fl_event_channel_new(
      messenger, "ares_bridge/events", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(
      plugin->event_channel, event_listen_cb, event_cancel_cb,
      plugin, nullptr);

  g_object_unref(plugin);
}
