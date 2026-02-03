set cc [C]
$cc cflags -I./vendor/mpack
$cc endcflags ./vendor/mpack/mpack.c -lzmq
$cc include <string.h>
$cc include <stdlib.h>
$cc include <unistd.h>
$cc include <zmq.h>
$cc include <mpack.h>

$cc code {
    static int encodeJimObj(mpack_writer_t *writer, Jim_Obj *obj, Jim_Interp *interp) {
        int len;
        const char *str;

        // Check if it's actually a list type
        if (Jim_IsList(obj)) {
            len = Jim_ListLength(interp, obj);
            mpack_start_array(writer, len);
            for (int i = 0; i < len; i++) {
                Jim_Obj *elem = Jim_ListGetIndex(interp, obj, i);
                if (encodeJimObj(writer, elem, interp) != JIM_OK) {
                    return JIM_ERR;
                }
            }
            mpack_finish_array(writer);
            return JIM_OK;
        }

        // Check if it's a number
        jim_wide wideValue;
        if (Jim_GetWide(interp, obj, &wideValue) == JIM_OK) {
            mpack_write_i64(writer, wideValue);
            return JIM_OK;
        }
        // Clear any error from failed conversion
        Jim_SetEmptyResult(interp);

        double doubleValue;
        if (Jim_GetDouble(interp, obj, &doubleValue) == JIM_OK) {
            mpack_write_double(writer, doubleValue);
            return JIM_OK;
        }
        // Clear any error from failed conversion
        Jim_SetEmptyResult(interp);

        // Treat as string
        str = Jim_GetString(obj, &len);
        mpack_write_str(writer, str, len);
        return JIM_OK;
    }

    static Jim_Obj* decodeMpackNode(mpack_node_t node, Jim_Interp *interp) {
        mpack_type_t type = mpack_node_type(node);

        switch (type) {
            case mpack_type_nil:
                return Jim_NewEmptyStringObj(interp);

            case mpack_type_bool:
                return Jim_NewIntObj(interp, mpack_node_bool(node) ? 1 : 0);

            case mpack_type_int:
                return Jim_NewIntObj(interp, mpack_node_i64(node));

            case mpack_type_uint:
                return Jim_NewIntObj(interp, mpack_node_u64(node));

            case mpack_type_float:
                return Jim_NewDoubleObj(interp, mpack_node_float(node));

            case mpack_type_double:
                return Jim_NewDoubleObj(interp, mpack_node_double(node));

            case mpack_type_str: {
                size_t len = mpack_node_strlen(node);
                const char *str = mpack_node_str(node);
                return Jim_NewStringObj(interp, str, len);
            }

            case mpack_type_bin: {
                size_t len = mpack_node_bin_size(node);
                const char *data = mpack_node_bin_data(node);
                return Jim_NewStringObj(interp, data, len);
            }

            case mpack_type_array: {
                size_t count = mpack_node_array_length(node);
                Jim_Obj *list = Jim_NewListObj(interp, NULL, 0);
                for (size_t i = 0; i < count; i++) {
                    mpack_node_t elem = mpack_node_array_at(node, i);
                    Jim_Obj *obj = decodeMpackNode(elem, interp);
                    if (obj == NULL) {
                        Jim_FreeNewObj(interp, list);
                        return NULL;
                    }
                    Jim_ListAppendElement(interp, list, obj);
                }
                return list;
            }

            case mpack_type_map: {
                // Convert map to a flat list of key-value pairs
                size_t count = mpack_node_map_count(node);
                Jim_Obj *list = Jim_NewListObj(interp, NULL, 0);
                for (size_t i = 0; i < count; i++) {
                    mpack_node_t key = mpack_node_map_key_at(node, i);
                    mpack_node_t value = mpack_node_map_value_at(node, i);

                    Jim_Obj *keyObj = decodeMpackNode(key, interp);
                    Jim_Obj *valueObj = decodeMpackNode(value, interp);

                    if (keyObj == NULL || valueObj == NULL) {
                        if (keyObj) Jim_FreeNewObj(interp, keyObj);
                        if (valueObj) Jim_FreeNewObj(interp, valueObj);
                        Jim_FreeNewObj(interp, list);
                        return NULL;
                    }

                    Jim_ListAppendElement(interp, list, keyObj);
                    Jim_ListAppendElement(interp, list, valueObj);
                }
                return list;
            }

            default:
                return NULL;
        }
    }
}

$cc proc zmqContext {} void* {
    static void *context = NULL;
    if (context == NULL) {
        context = zmq_ctx_new();
    }
    return context;
}

$cc proc zmqSocket {char* socketType} void* {
    void *context = zmqContext();
    int type;
    if (strcmp(socketType, "REQ") == 0) {
        type = ZMQ_REQ;
    } else if (strcmp(socketType, "REP") == 0) {
        type = ZMQ_REP;
    } else if (strcmp(socketType, "PUSH") == 0) {
        type = ZMQ_PUSH;
    } else if (strcmp(socketType, "PULL") == 0) {
        type = ZMQ_PULL;
    } else {
        Jim_SetResultString(interp, "Invalid socket type", -1);
        return NULL;
    }
    void *socket = zmq_socket(context, type);
    return socket;
}

$cc proc zmqBind {void* socket char* endpoint} int {
    return zmq_bind(socket, endpoint);
}

$cc proc zmqConnect {void* socket char* endpoint} int {
    return zmq_connect(socket, endpoint);
}

$cc proc zmqSend {void* socket Jim_Obj* obj} void {
    char *buffer;
    size_t size;
    mpack_writer_t writer;
    mpack_writer_init_growable(&writer, &buffer, &size);

    if (encodeJimObj(&writer, obj, interp) != JIM_OK) {
        mpack_writer_destroy(&writer);
        MPACK_FREE(buffer);
        Jim_SetResultString(interp, "Failed to encode object", -1);
        return;
    }

    if (mpack_writer_destroy(&writer) != mpack_ok) {
        MPACK_FREE(buffer);
        Jim_SetResultString(interp, "Failed to finalize msgpack encoding", -1);
        return;
    }

    // Send via ZeroMQ
    zmq_send(socket, buffer, size, 0);
    MPACK_FREE(buffer);
}

$cc proc zmqRecv {void* socket} Jim_Obj* {
    zmq_msg_t msg;
    zmq_msg_init(&msg);

    int rc = zmq_msg_recv(&msg, socket, 0);
    if (rc == -1) {
        zmq_msg_close(&msg);
        Jim_SetResultString(interp, "Failed to receive message", -1);
        return NULL;
    }

    size_t size = zmq_msg_size(&msg);
    char *data = (char*)zmq_msg_data(&msg);

    mpack_tree_t tree;
    mpack_tree_init_data(&tree, data, size);
    mpack_tree_parse(&tree);

    if (mpack_tree_error(&tree) != mpack_ok) {
        mpack_tree_destroy(&tree);
        zmq_msg_close(&msg);
        Jim_SetResultString(interp, "Failed to parse msgpack data", -1);
        return NULL;
    }

    mpack_node_t root = mpack_tree_root(&tree);
    Jim_Obj *result = decodeMpackNode(root, interp);

    mpack_tree_destroy(&tree);
    zmq_msg_close(&msg);

    if (result == NULL) {
        Jim_SetResultString(interp, "Failed to decode msgpack data", -1);
        return NULL;
    }

    return result;
}

set mpack [$cc compile]

