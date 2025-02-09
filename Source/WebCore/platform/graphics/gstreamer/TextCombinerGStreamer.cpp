/*
 * Copyright (C) 2013 Cable Television Laboratories, Inc.
 * Copyright (C) 2021 Igalia S.L.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
 * ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "TextCombinerGStreamer.h"

#if ENABLE(VIDEO) && USE(GSTREAMER)

#include "GStreamerCommon.h"
#include "TextCombinerPadGStreamer.h"
#include <wtf/glib/WTFGType.h>

static GstStaticPadTemplate sinkTemplate = GST_STATIC_PAD_TEMPLATE("sink_%u", GST_PAD_SINK, GST_PAD_REQUEST, GST_STATIC_CAPS_ANY);

static GstStaticPadTemplate srcTemplate = GST_STATIC_PAD_TEMPLATE("src", GST_PAD_SRC, GST_PAD_ALWAYS, GST_STATIC_CAPS_ANY);

GST_DEBUG_CATEGORY_STATIC(webkitTextCombinerDebug);
#define GST_CAT_DEFAULT webkitTextCombinerDebug

struct _WebKitTextCombinerPrivate {
    GRefPtr<GstElement> combinerElement;
};

#define webkit_text_combiner_parent_class parent_class
WEBKIT_DEFINE_TYPE_WITH_CODE(WebKitTextCombiner, webkit_text_combiner, GST_TYPE_BIN,
    GST_DEBUG_CATEGORY_INIT(webkitTextCombinerDebug, "webkittextcombiner", 0, "webkit text combiner"))

using namespace WebCore;

void webKitTextCombinerHandleCapsEvent(WebKitTextCombiner* combiner, GstPad* pad, GstEvent* event)
{
    GstCaps* caps;
    gst_event_parse_caps(event, &caps);
    ASSERT(caps);
    GST_DEBUG_OBJECT(combiner, "Handling caps %" GST_PTR_FORMAT, caps);

    auto target = adoptGRef(gst_ghost_pad_get_target(GST_GHOST_PAD(pad)));
    auto targetParent = target ? adoptGRef(gst_pad_get_parent_element(target.get())) : nullptr;
    auto* combinerPad = WEBKIT_TEXT_COMBINER_PAD(pad);

    GRefPtr<GstPad> internalPad;
    g_object_get(combinerPad, "inner-combiner-pad", &internalPad.outPtr(), nullptr);

    auto textCaps = adoptGRef(gst_caps_new_empty_simple("text/x-raw"));
    if (gst_caps_can_intersect(textCaps.get(), caps)) {
        // Caps are plain text, we want a WebVTT encoder between the ghostpad and the combinerElement.
        if (!target || gstElementFactoryEquals(targetParent.get(), "webvttenc"_s)) {
            GST_DEBUG_OBJECT(combiner, "Setting up a WebVTT encoder");
            auto* encoder = gst_element_factory_make("webvttenc", nullptr);
            ASSERT(encoder);

            gst_bin_add(GST_BIN_CAST(combiner), encoder);
            gst_element_sync_state_with_parent(encoder);

            // Switch the ghostpad to target the WebVTT encoder.
            auto sinkPad = adoptGRef(gst_element_get_static_pad(encoder, "sink"));
            ASSERT(sinkPad);

            gst_ghost_pad_set_target(GST_GHOST_PAD(pad), sinkPad.get());

            // Connect the WebVTT encoder to the combinerElement.
            auto srcPad = adoptGRef(gst_element_get_static_pad(encoder, "src"));
            ASSERT(srcPad);

            gst_pad_link(srcPad.get(), internalPad.get());
        } // Else: pipeline is already correct.
    } else {
        // Caps are not plain text, we assume it's WebVTT.

        // Remove the WebVTT encoder if present.
        if (target && gstElementFactoryEquals(targetParent.get(), "webvttenc"_s)) {
            GST_DEBUG_OBJECT(combiner, "Removing WebVTT encoder");
            gst_bin_remove(GST_BIN_CAST(combiner), targetParent.get());
            target = nullptr;
            targetParent = nullptr;
        }

        // Link the pad to the combinerElement.
        if (!target) {
            GST_DEBUG_OBJECT(combiner, "Associating %" GST_PTR_FORMAT " to %" GST_PTR_FORMAT, internalPad.get(), pad);
            gst_ghost_pad_set_target(GST_GHOST_PAD(pad), internalPad.get());
        } // Else: pipeline is already correct.
    }
}

static GstPad* webkitTextCombinerRequestNewPad(GstElement* element, GstPadTemplate* templ, const char* name, const GstCaps* caps)
{
    auto* combiner = WEBKIT_TEXT_COMBINER(element);
    ASSERT(combiner);

    GST_DEBUG_OBJECT(element, "Requesting new sink pad");
    auto* ghostPad = GST_PAD_CAST(g_object_new(WEBKIT_TYPE_TEXT_COMBINER_PAD, "direction", GST_PAD_SINK, nullptr));
    ASSERT(ghostPad);

    auto* internalPad = gst_element_request_pad(combiner->priv->combinerElement.get(), templ, name, caps);
    g_object_set(WEBKIT_TEXT_COMBINER_PAD(ghostPad), "inner-combiner-pad", internalPad, nullptr);

    gst_pad_set_active(ghostPad, true);
    gst_element_add_pad(GST_ELEMENT_CAST(combiner), ghostPad);
    return ghostPad;
}

static void webkitTextCombinerReleasePad(GstElement* element, GstPad* pad)
{
    auto* combiner = WEBKIT_TEXT_COMBINER(element);
    auto* combinerPad = WEBKIT_TEXT_COMBINER_PAD(pad);

    if (auto target = adoptGRef(gst_ghost_pad_get_target(GST_GHOST_PAD(pad)))) {
        auto parent = adoptGRef(gst_pad_get_parent_element(target.get()));
        ASSERT(parent);
        if (gstElementFactoryEquals(parent.get(), "webvttenc"_s)) {
            gst_element_set_state(parent.get(), GST_STATE_NULL);
            gst_bin_remove(GST_BIN_CAST(combiner), parent.get());
        }
    }

    auto internalPad = adoptGRef(webKitTextCombinerPadLeakInternalPadRef(combinerPad));
    gst_element_release_request_pad(combiner->priv->combinerElement.get(), internalPad.get());

    gst_element_remove_pad(element, pad);
}

static void webKitTextCombinerConstructed(GObject* object)
{
    GST_CALL_PARENT(G_OBJECT_CLASS, constructed, (object));

    auto* combiner = WEBKIT_TEXT_COMBINER(object);
    auto* priv = combiner->priv;

    // For now a funnel is used, but a better combiner, compatible with playbin3 use-cases, would be concat.
    priv->combinerElement = gst_element_factory_make("funnel", nullptr);
    ASSERT(priv->combinerElement);

    gst_bin_add(GST_BIN_CAST(combiner), priv->combinerElement.get());

    auto pad = adoptGRef(gst_element_get_static_pad(priv->combinerElement.get(), "src"));
    ASSERT(pad);

    gst_element_add_pad(GST_ELEMENT_CAST(combiner), gst_ghost_pad_new("src", pad.get()));
}

static void webkit_text_combiner_class_init(WebKitTextCombinerClass* klass)
{
    auto* elementClass = GST_ELEMENT_CLASS(klass);
    auto* objectClass = G_OBJECT_CLASS(klass);

    objectClass->constructed = webKitTextCombinerConstructed;

    gst_element_class_add_pad_template(elementClass, gst_static_pad_template_get(&sinkTemplate));
    gst_element_class_add_pad_template(elementClass, gst_static_pad_template_get(&srcTemplate));

    gst_element_class_set_metadata(elementClass, "WebKit text combiner", "Generic",
        "A combiner that accepts any caps, but converts plain text to WebVTT",
        "Brendan Long <b.long@cablelabs.com>");

    elementClass->request_new_pad = GST_DEBUG_FUNCPTR(webkitTextCombinerRequestNewPad);
    elementClass->release_pad = GST_DEBUG_FUNCPTR(webkitTextCombinerReleasePad);
}

GstElement* webkitTextCombinerNew()
{
    // The combiner relies on webvttenc, fail early if it's not there.
    if (!isGStreamerPluginAvailable("subenc")) {
        WTFLogAlways("WebKit wasn't able to find a WebVTT encoder. Not continuing without platform support for subtitles.");
        return nullptr;
    }

    return GST_ELEMENT(g_object_new(WEBKIT_TYPE_TEXT_COMBINER, nullptr));
}

#endif // ENABLE(VIDEO) && USE(GSTREAMER)
