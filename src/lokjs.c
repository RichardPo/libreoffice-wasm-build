/* SPDX-License-Identifier: MPL-2.0 */
/*
 * lokjs: a small program that starts LibreOffice in LibreOfficeKit mode inside WebAssembly and
 * gives JavaScript a flat C API to it. It is linked against an unmodified LibreOffice build
 * (the static libraries listed in soffice.js.linkdeps), in place of soffice's own main().
 *
 * Threading: with -sPROXY_TO_PTHREAD, main() runs on a pthread. main() initialises LOK in
 * "unipoll" mode and calls runLoop(), which hands LibreOffice's main loop to the Emscripten event
 * loop of that same pthread. JavaScript on that thread (the zetajs scripts from
 * Module.uno_scripts, which LOK loads while initialising UNO) can then call the lokjs_* functions
 * between main-loop iterations. LOK callbacks go to Module.lokCallback on that thread.
 */

#include <stdbool.h>
#include <stdlib.h>

#include <emscripten.h>

#define LOK_USE_UNSTABLE_API
#include <LibreOfficeKit/LibreOfficeKit.h>

LibreOfficeKit* libreofficekit_hook_2(const char* install_path, const char* user_profile_path);

static LibreOfficeKit* g_lok;
/* 0 = not started, 1 = LOK initialised, 2 = main loop running (documents can be loaded),
   -1 = runLoop() returned: LibreOffice's desktop exited instead of handing its main loop to
   the browser, so VCL is shut down and nothing can be loaded. */
static int g_state;

/* LibreOffice's Emscripten main loop calls this ~100 times a second (ImplYield). Input comes from
   JavaScript on the same thread in between, so there is never anything to wait for here:
   0 = no event, < 0 would mean "quit". */
static int lokjs_poll(void* data, int timeout_us)
{
    (void)data;
    (void)timeout_us;
    return 0;
}

static void lokjs_wake(void* data)
{
    (void)data;
}

/* doc == 0 for callbacks of the LibreOfficeKit instance itself. */
static void lokjs_deliver(LibreOfficeKitDocument* doc, int type, const char* payload)
{
    EM_ASM({
        if (typeof Module.lokCallback === 'function')
            Module.lokCallback($0, $1, $2 ? UTF8ToString($2) : '');
    }, doc, type, payload);
}

static void lokjs_global_callback(int type, const char* payload, void* data)
{
    (void)data;
    lokjs_deliver(0, type, payload);
}

static void lokjs_document_callback(int type, const char* payload, void* data)
{
    lokjs_deliver((LibreOfficeKitDocument*)data, type, payload);
}

/* Runs on the first event-loop tick after runLoop() has handed the main loop to Emscripten,
   i.e. once soffice_main() has finished initialising the desktop. */
static void lokjs_notify_ready(void* arg)
{
    (void)arg;
    if (g_state != 1)
        return;
    g_state = 2;
    EM_ASM({ if (typeof Module.lokReady === 'function') Module.lokReady(); });
}

int main(int argc, char** argv)
{
    (void)argc;
    (void)argv;
    /* Single-threaded LOK: no separate main thread, the caller runs the loop. */
    setenv("SAL_LOK_OPTIONS", "unipoll", 0);
    g_lok = libreofficekit_hook_2(NULL, NULL);
    if (!g_lok)
        return 1;
    g_state = 1;
    g_lok->pClass->registerCallback(g_lok, lokjs_global_callback, NULL);
    emscripten_async_call(lokjs_notify_ready, NULL, 0);
    /* Runs soffice_main(), which ends in emscripten_set_main_loop_arg() and does not return. */
    g_lok->pClass->runLoop(g_lok, lokjs_poll, lokjs_wake, g_lok);
    g_state = -1;
    EM_ASM({ console.error('lokjs: runLoop() returned; LibreOffice is not running'); });
    return 0;
}

/* ---- LibreOfficeKit ------------------------------------------------------------------------ */

EMSCRIPTEN_KEEPALIVE int lokjs_state(void) { return g_state; }

/* Returned strings are malloc'ed by LibreOffice; release them with lokjs_free(). */
EMSCRIPTEN_KEEPALIVE void lokjs_free(void* p) { free(p); }

EMSCRIPTEN_KEEPALIVE char* lokjs_get_error(void) { return g_lok->pClass->getError(g_lok); }

EMSCRIPTEN_KEEPALIVE void lokjs_set_optional_features(unsigned low, unsigned high)
{
    g_lok->pClass->setOptionalFeatures(g_lok, ((unsigned long long)high << 32) | low);
}

EMSCRIPTEN_KEEPALIVE void lokjs_set_option(const char* option, const char* value)
{
    g_lok->pClass->setOption(g_lok, option, value);
}

EMSCRIPTEN_KEEPALIVE LibreOfficeKitDocument* lokjs_document_load(const char* url, const char* options)
{
    return g_lok->pClass->documentLoadWithOptions(g_lok, url, options);
}

/* ---- LibreOfficeKitDocument ---------------------------------------------------------------- */

EMSCRIPTEN_KEEPALIVE void lokjs_document_destroy(LibreOfficeKitDocument* d) { d->pClass->destroy(d); }

EMSCRIPTEN_KEEPALIVE void lokjs_register_callback(LibreOfficeKitDocument* d)
{
    d->pClass->registerCallback(d, lokjs_document_callback, d);
}

EMSCRIPTEN_KEEPALIVE void lokjs_initialize_for_rendering(LibreOfficeKitDocument* d, const char* args)
{
    d->pClass->initializeForRendering(d, args);
}

EMSCRIPTEN_KEEPALIVE int lokjs_get_tile_mode(LibreOfficeKitDocument* d) { return d->pClass->getTileMode(d); }

EMSCRIPTEN_KEEPALIVE int lokjs_document_width(LibreOfficeKitDocument* d)
{
    long w = 0, h = 0;
    d->pClass->getDocumentSize(d, &w, &h);
    return (int)w;
}

EMSCRIPTEN_KEEPALIVE int lokjs_document_height(LibreOfficeKitDocument* d)
{
    long w = 0, h = 0;
    d->pClass->getDocumentSize(d, &w, &h);
    return (int)h;
}

EMSCRIPTEN_KEEPALIVE char* lokjs_get_part_page_rectangles(LibreOfficeKitDocument* d)
{
    return d->pClass->getPartPageRectangles(d);
}

EMSCRIPTEN_KEEPALIVE void lokjs_paint_tile(LibreOfficeKitDocument* d, unsigned char* buffer,
                                           int canvas_width, int canvas_height,
                                           int x, int y, int width, int height)
{
    d->pClass->paintTile(d, buffer, canvas_width, canvas_height, x, y, width, height);
}

EMSCRIPTEN_KEEPALIVE void lokjs_post_key(LibreOfficeKitDocument* d, int type, int char_code, int key_code)
{
    d->pClass->postKeyEvent(d, type, char_code, key_code);
}

EMSCRIPTEN_KEEPALIVE void lokjs_post_mouse(LibreOfficeKitDocument* d, int type, int x, int y,
                                           int count, int buttons, int modifier)
{
    d->pClass->postMouseEvent(d, type, x, y, count, buttons, modifier);
}

EMSCRIPTEN_KEEPALIVE void lokjs_post_ext_text_input(LibreOfficeKitDocument* d, unsigned window_id,
                                                    int type, const char* text)
{
    d->pClass->postWindowExtTextInputEvent(d, window_id, type, text);
}

EMSCRIPTEN_KEEPALIVE void lokjs_post_uno(LibreOfficeKitDocument* d, const char* command,
                                         const char* args, int notify_when_finished)
{
    d->pClass->postUnoCommand(d, command, args, notify_when_finished != 0);
}

EMSCRIPTEN_KEEPALIVE void lokjs_set_text_selection(LibreOfficeKitDocument* d, int type, int x, int y)
{
    d->pClass->setTextSelection(d, type, x, y);
}

EMSCRIPTEN_KEEPALIVE char* lokjs_get_text_selection(LibreOfficeKitDocument* d, const char* mime_type)
{
    return d->pClass->getTextSelection(d, mime_type, NULL);
}

EMSCRIPTEN_KEEPALIVE int lokjs_paste(LibreOfficeKitDocument* d, const char* mime_type,
                                     const char* data, int size)
{
    return d->pClass->paste(d, mime_type, data, (size_t)size) ? 1 : 0;
}

EMSCRIPTEN_KEEPALIVE void lokjs_reset_selection(LibreOfficeKitDocument* d) { d->pClass->resetSelection(d); }

EMSCRIPTEN_KEEPALIVE char* lokjs_get_command_values(LibreOfficeKitDocument* d, const char* command)
{
    return d->pClass->getCommandValues(d, command);
}

EMSCRIPTEN_KEEPALIVE void lokjs_set_client_zoom(LibreOfficeKitDocument* d, int tile_pixel_width,
                                                int tile_pixel_height, int tile_twip_width,
                                                int tile_twip_height)
{
    d->pClass->setClientZoom(d, tile_pixel_width, tile_pixel_height, tile_twip_width, tile_twip_height);
}

EMSCRIPTEN_KEEPALIVE void lokjs_set_client_visible_area(LibreOfficeKitDocument* d, int x, int y,
                                                        int width, int height)
{
    d->pClass->setClientVisibleArea(d, x, y, width, height);
}

EMSCRIPTEN_KEEPALIVE int lokjs_create_view(LibreOfficeKitDocument* d) { return d->pClass->createView(d); }
EMSCRIPTEN_KEEPALIVE void lokjs_set_view(LibreOfficeKitDocument* d, int id) { d->pClass->setView(d, id); }
EMSCRIPTEN_KEEPALIVE int lokjs_get_view(LibreOfficeKitDocument* d) { return d->pClass->getView(d); }

EMSCRIPTEN_KEEPALIVE int lokjs_save_as(LibreOfficeKitDocument* d, const char* url, const char* format,
                                       const char* filter_options)
{
    return d->pClass->saveAs(d, url, format, filter_options);
}
