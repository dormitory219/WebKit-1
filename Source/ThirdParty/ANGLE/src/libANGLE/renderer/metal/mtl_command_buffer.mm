//
// Copyright 2019 The ANGLE Project Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// mtl_command_buffer.mm:
//      Implementations of Metal framework's MTLCommandBuffer, MTLCommandQueue,
//      MTLCommandEncoder's wrappers.
//

#include "libANGLE/renderer/metal/mtl_command_buffer.h"

#include <cassert>
#if ANGLE_MTL_SIMULATE_DISCARD_FRAMEBUFFER
#    include <random>
#endif

#include "common/debug.h"
#include "libANGLE/renderer/metal/mtl_occlusion_query_pool.h"
#include "libANGLE/renderer/metal/mtl_resources.h"

// Use to compare the new values with the values already set in the command encoder:
static inline bool operator==(const MTLViewport &lhs, const MTLViewport &rhs)
{
    return memcmp(&lhs, &rhs, sizeof(lhs)) == 0;
}

static inline bool operator==(const MTLScissorRect &lhs, const MTLScissorRect &rhs)
{
    return memcmp(&lhs, &rhs, sizeof(lhs)) == 0;
}

namespace rx
{
namespace mtl
{

namespace
{

#define ANGLE_MTL_CMD_X(PROC)            \
    PROC(Invalid)                        \
    PROC(SetRenderPipelineState)         \
    PROC(SetTriangleFillMode)            \
    PROC(SetFrontFacingWinding)          \
    PROC(SetCullMode)                    \
    PROC(SetDepthStencilState)           \
    PROC(SetDepthBias)                   \
    PROC(SetStencilRefVals)              \
    PROC(SetViewport)                    \
    PROC(SetScissorRect)                 \
    PROC(SetBlendColor)                  \
    PROC(SetVertexBuffer)                \
    PROC(SetVertexBufferOffset)          \
    PROC(SetVertexBytes)                 \
    PROC(SetVertexSamplerState)          \
    PROC(SetVertexTexture)               \
    PROC(SetFragmentBuffer)              \
    PROC(SetFragmentBufferOffset)        \
    PROC(SetFragmentBytes)               \
    PROC(SetFragmentSamplerState)        \
    PROC(SetFragmentTexture)             \
    PROC(Draw)                           \
    PROC(DrawInstanced)                  \
    PROC(DrawIndexed)                    \
    PROC(DrawIndexedInstanced)           \
    PROC(DrawIndexedInstancedBaseVertex) \
    PROC(SetVisibilityResultMode)        \
    PROC(UseResource)                    \
    PROC(MemoryBarrierWithResource)      \
    PROC(InsertDebugsign)                \
    PROC(PushDebugGroup)                 \
    PROC(PopDebugGroup)

#define ANGLE_MTL_TYPE_DECL(CMD) CMD,

// Command types
enum class CmdType : uint8_t
{
    ANGLE_MTL_CMD_X(ANGLE_MTL_TYPE_DECL)
};

// Commands decoder
void InvalidCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    UNREACHABLE();
}

void SetRenderPipelineStateCmd(id<MTLRenderCommandEncoder> encoder,
                               IntermediateCommandStream *stream)
{
    auto state = stream->fetch<id<MTLRenderPipelineState>>();
    [encoder setRenderPipelineState:state];
    [state ANGLE_MTL_RELEASE];
}

void SetTriangleFillModeCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    auto mode = stream->fetch<MTLTriangleFillMode>();
    [encoder setTriangleFillMode:mode];
}

void SetFrontFacingWindingCmd(id<MTLRenderCommandEncoder> encoder,
                              IntermediateCommandStream *stream)
{
    auto winding = stream->fetch<MTLWinding>();
    [encoder setFrontFacingWinding:winding];
}

void SetCullModeCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    auto mode = stream->fetch<MTLCullMode>();
    [encoder setCullMode:mode];
}

void SetDepthStencilStateCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    auto state = stream->fetch<id<MTLDepthStencilState>>();
    [encoder setDepthStencilState:state];
    [state ANGLE_MTL_RELEASE];
}

void SetDepthBiasCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    auto depthBias  = stream->fetch<float>();
    auto slopeScale = stream->fetch<float>();
    auto clamp      = stream->fetch<float>();
    [encoder setDepthBias:depthBias slopeScale:slopeScale clamp:clamp];
}

void SetStencilRefValsCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    // Metal has some bugs when reference values are larger than 0xff
    uint32_t frontRef = stream->fetch<uint32_t>();
    uint32_t backRef  = stream->fetch<uint32_t>();
    [encoder setStencilFrontReferenceValue:frontRef backReferenceValue:backRef];
}

void SetViewportCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    auto viewport = stream->fetch<MTLViewport>();
    [encoder setViewport:viewport];
}

void SetScissorRectCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    auto rect = stream->fetch<MTLScissorRect>();
    [encoder setScissorRect:rect];
}

void SetBlendColorCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    float r = stream->fetch<float>();
    float g = stream->fetch<float>();
    float b = stream->fetch<float>();
    float a = stream->fetch<float>();
    [encoder setBlendColorRed:r green:g blue:b alpha:a];
}

void SetVertexBufferCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    auto buffer = stream->fetch<id<MTLBuffer>>();
    auto offset = stream->fetch<uint32_t>();
    auto index  = stream->fetch<uint32_t>();
    [encoder setVertexBuffer:buffer offset:offset atIndex:index];
    [buffer ANGLE_MTL_RELEASE];
}

void SetVertexBufferOffsetCmd(id<MTLRenderCommandEncoder> encoder,
                              IntermediateCommandStream *stream)
{
    auto offset = stream->fetch<uint32_t>();
    auto index  = stream->fetch<uint32_t>();
    [encoder setVertexBufferOffset:offset atIndex:index];
}

void SetVertexBytesCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    auto size  = stream->fetch<size_t>();
    auto bytes = stream->fetch(size);
    auto index = stream->fetch<uint32_t>();
    [encoder setVertexBytes:bytes length:size atIndex:index];
}

void SetVertexSamplerStateCmd(id<MTLRenderCommandEncoder> encoder,
                              IntermediateCommandStream *stream)
{
    auto state        = stream->fetch<id<MTLSamplerState>>();
    float lodMinClamp = stream->fetch<float>();
    float lodMaxClamp = stream->fetch<float>();
    auto index        = stream->fetch<uint32_t>();
    [encoder setVertexSamplerState:state
                       lodMinClamp:lodMinClamp
                       lodMaxClamp:lodMaxClamp
                           atIndex:index];

    [state ANGLE_MTL_RELEASE];
}

void SetVertexTextureCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    auto texture = stream->fetch<id<MTLTexture>>();
    auto index   = stream->fetch<uint32_t>();
    [encoder setVertexTexture:texture atIndex:index];
    [texture ANGLE_MTL_RELEASE];
}

void SetFragmentBufferCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    auto buffer = stream->fetch<id<MTLBuffer>>();
    auto offset = stream->fetch<uint32_t>();
    auto index  = stream->fetch<uint32_t>();
    [encoder setFragmentBuffer:buffer offset:offset atIndex:index];
    [buffer ANGLE_MTL_RELEASE];
}

void SetFragmentBufferOffsetCmd(id<MTLRenderCommandEncoder> encoder,
                                IntermediateCommandStream *stream)
{
    auto offset = stream->fetch<uint32_t>();
    auto index  = stream->fetch<uint32_t>();
    [encoder setFragmentBufferOffset:offset atIndex:index];
}

void SetFragmentBytesCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    auto size  = stream->fetch<size_t>();
    auto bytes = stream->fetch(size);
    auto index = stream->fetch<uint32_t>();
    [encoder setFragmentBytes:bytes length:size atIndex:index];
}

void SetFragmentSamplerStateCmd(id<MTLRenderCommandEncoder> encoder,
                                IntermediateCommandStream *stream)
{
    auto state        = stream->fetch<id<MTLSamplerState>>();
    float lodMinClamp = stream->fetch<float>();
    float lodMaxClamp = stream->fetch<float>();
    auto index        = stream->fetch<uint32_t>();
    [encoder setFragmentSamplerState:state
                         lodMinClamp:lodMinClamp
                         lodMaxClamp:lodMaxClamp
                             atIndex:index];
    [state ANGLE_MTL_RELEASE];
}

void SetFragmentTextureCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    auto texture = stream->fetch<id<MTLTexture>>();
    auto index   = stream->fetch<uint32_t>();
    [encoder setFragmentTexture:texture atIndex:index];
    [texture ANGLE_MTL_RELEASE];
}

void DrawCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    auto primitiveType = stream->fetch<MTLPrimitiveType>();
    auto vertexStart   = stream->fetch<uint32_t>();
    auto vertexCount   = stream->fetch<uint32_t>();
    [encoder drawPrimitives:primitiveType vertexStart:vertexStart vertexCount:vertexCount];
}

void DrawInstancedCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    auto primitiveType = stream->fetch<MTLPrimitiveType>();
    auto vertexStart   = stream->fetch<uint32_t>();
    auto vertexCount   = stream->fetch<uint32_t>();
    auto instances     = stream->fetch<uint32_t>();
    [encoder drawPrimitives:primitiveType
                vertexStart:vertexStart
                vertexCount:vertexCount
              instanceCount:instances];
}

void DrawIndexedCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    auto primitiveType = stream->fetch<MTLPrimitiveType>();
    auto indexCount    = stream->fetch<uint32_t>();
    auto indexType     = stream->fetch<MTLIndexType>();
    auto indexBuffer   = stream->fetch<id<MTLBuffer>>();
    auto bufferOffset  = stream->fetch<size_t>();
    [encoder drawIndexedPrimitives:primitiveType
                        indexCount:indexCount
                         indexType:indexType
                       indexBuffer:indexBuffer
                 indexBufferOffset:bufferOffset];
    [indexBuffer ANGLE_MTL_RELEASE];
}

void DrawIndexedInstancedCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    auto primitiveType = stream->fetch<MTLPrimitiveType>();
    auto indexCount    = stream->fetch<uint32_t>();
    auto indexType     = stream->fetch<MTLIndexType>();
    auto indexBuffer   = stream->fetch<id<MTLBuffer>>();
    auto bufferOffset  = stream->fetch<size_t>();
    auto instances     = stream->fetch<uint32_t>();
    [encoder drawIndexedPrimitives:primitiveType
                        indexCount:indexCount
                         indexType:indexType
                       indexBuffer:indexBuffer
                 indexBufferOffset:bufferOffset
                     instanceCount:instances];
    [indexBuffer ANGLE_MTL_RELEASE];
}

void DrawIndexedInstancedBaseVertexCmd(id<MTLRenderCommandEncoder> encoder,
                                       IntermediateCommandStream *stream)
{
    auto primitiveType = stream->fetch<MTLPrimitiveType>();
    auto indexCount    = stream->fetch<uint32_t>();
    auto indexType     = stream->fetch<MTLIndexType>();
    auto indexBuffer   = stream->fetch<id<MTLBuffer>>();
    auto bufferOffset  = stream->fetch<size_t>();
    auto instances     = stream->fetch<uint32_t>();
    auto baseVertex    = stream->fetch<uint32_t>();
    [encoder drawIndexedPrimitives:primitiveType
                        indexCount:indexCount
                         indexType:indexType
                       indexBuffer:indexBuffer
                 indexBufferOffset:bufferOffset
                     instanceCount:instances
                        baseVertex:baseVertex
                      baseInstance:0];
    [indexBuffer ANGLE_MTL_RELEASE];
}

void SetVisibilityResultModeCmd(id<MTLRenderCommandEncoder> encoder,
                                IntermediateCommandStream *stream)
{
    auto mode   = stream->fetch<MTLVisibilityResultMode>();
    auto offset = stream->fetch<size_t>();
    [encoder setVisibilityResultMode:mode offset:offset];
}

void UseResourceCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    auto resource = stream->fetch<id<MTLResource>>();
    auto usage    = stream->fetch<MTLResourceUsage>();
    auto stages   = stream->fetch<mtl::RenderStages>();
    ANGLE_UNUSED_VARIABLE(stages);
#if defined(__IPHONE_13_0) || defined(__MAC_10_15)
    if (ANGLE_APPLE_AVAILABLE_XCI(10.15, 13.0, 13.0))
    {
        [encoder useResource:resource usage:usage stages:stages];
    }
    else
#endif
    {
        [encoder useResource:resource usage:usage];
    }
    [resource ANGLE_MTL_RELEASE];
}

void MemoryBarrierWithResourceCmd(id<MTLRenderCommandEncoder> encoder,
                                  IntermediateCommandStream *stream)
{
    auto resource = stream->fetch<id<MTLResource>>();
    auto after    = stream->fetch<mtl::RenderStages>();
    auto before   = stream->fetch<mtl::RenderStages>();
    ANGLE_UNUSED_VARIABLE(after);
    ANGLE_UNUSED_VARIABLE(before);
#if defined(__MAC_10_14) && (TARGET_OS_OSX || TARGET_OS_MACCATALYST)
    if (ANGLE_APPLE_AVAILABLE_XC(10.14, 13.0))
    {
        [encoder memoryBarrierWithResources:&resource
                                      count:1
                                afterStages:after
                               beforeStages:before];
    }
#endif
    [resource ANGLE_MTL_RELEASE];
}

void InsertDebugsignCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    auto label = stream->fetch<NSString *>();
    [encoder insertDebugSignpost:label];
    [label ANGLE_MTL_RELEASE];
}

void PushDebugGroupCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    auto label = stream->fetch<NSString *>();
    [encoder pushDebugGroup:label];
    [label ANGLE_MTL_RELEASE];
}

void PopDebugGroupCmd(id<MTLRenderCommandEncoder> encoder, IntermediateCommandStream *stream)
{
    [encoder popDebugGroup];
}

// Command encoder mapping
#define ANGLE_MTL_CMD_MAP(CMD) CMD##Cmd,

using CommandEncoderFunc = void (*)(id<MTLRenderCommandEncoder>, IntermediateCommandStream *);
constexpr CommandEncoderFunc gCommandEncoders[] = {ANGLE_MTL_CMD_X(ANGLE_MTL_CMD_MAP)};

NSString *cppLabelToObjC(const std::string &marker)
{
    auto label = [NSString stringWithUTF8String:marker.c_str()];
    if (!label)
    {
        // This can happen if the string is not a valid ascii string.
        label = @"Invalid ASCII string";
    }
    return label;
}
}

// CommandQueue implementation
void CommandQueue::reset()
{
    finishAllCommands();
    ParentClass::reset();
}

void CommandQueue::set(id<MTLCommandQueue> metalQueue)
{
    finishAllCommands();

    ParentClass::set(metalQueue);
}

void CommandQueue::finishAllCommands()
{
    {
        // Copy to temp list
        std::lock_guard<std::mutex> lg(mLock);

        for (CmdBufferQueueEntry &metalBufferEntry : mMetalCmdBuffers)
        {
            mMetalCmdBuffersTmp.push_back(metalBufferEntry);
        }

        mMetalCmdBuffers.clear();
    }

    // Wait for command buffers to finish
    for (CmdBufferQueueEntry &metalBufferEntry : mMetalCmdBuffersTmp)
    {
        [metalBufferEntry.buffer waitUntilCompleted];
    }
    mMetalCmdBuffersTmp.clear();
}

void CommandQueue::ensureResourceReadyForCPU(const ResourceRef &resource)
{
    if (!resource)
    {
        return;
    }

    ensureResourceReadyForCPU(resource.get());
}

void CommandQueue::ensureResourceReadyForCPU(Resource *resource)
{
    mLock.lock();
    while (isResourceBeingUsedByGPU(resource) && !mMetalCmdBuffers.empty())
    {
        CmdBufferQueueEntry metalBufferEntry = mMetalCmdBuffers.front();
        mMetalCmdBuffers.pop_front();
        mLock.unlock();

        ANGLE_MTL_LOG("Waiting for MTLCommandBuffer %llu:%p", metalBufferEntry.serial,
                      metalBufferEntry.buffer.get());
        [metalBufferEntry.buffer waitUntilCompleted];

        mLock.lock();
    }
    mLock.unlock();

    // This can happen if the resource is read then write in the same command buffer.
    // So it is the responsitibily of outer code to ensure the command buffer is commit before
    // the resource can be read or written again
    ASSERT(!isResourceBeingUsedByGPU(resource));
}

bool CommandQueue::isResourceBeingUsedByGPU(const Resource *resource) const
{
    if (!resource)
    {
        return false;
    }

    return mCompletedBufferSerial.load(std::memory_order_relaxed) <
           resource->getCommandBufferQueueSerial();
}

bool CommandQueue::resourceHasPendingWorks(const Resource *resource) const
{
    if (!resource)
    {
        return false;
    }

    return mCommittedBufferSerial.load(std::memory_order_relaxed) <
           resource->getCommandBufferQueueSerial();
}

AutoObjCPtr<id<MTLCommandBuffer>> CommandQueue::makeMetalCommandBuffer(uint64_t *queueSerialOut)
{
    ANGLE_MTL_OBJC_SCOPE
    {
        AutoObjCPtr<id<MTLCommandBuffer>> metalCmdBuffer = [get() commandBuffer];

        std::lock_guard<std::mutex> lg(mLock);

        uint64_t serial = mQueueSerialCounter++;

        mMetalCmdBuffers.push_back({metalCmdBuffer, serial});

        ANGLE_MTL_LOG("Created MTLCommandBuffer %llu:%p", serial, metalCmdBuffer.get());

        [metalCmdBuffer addCompletedHandler:^(id<MTLCommandBuffer> buf) {
          onCommandBufferCompleted(buf, serial);
        }];

        [metalCmdBuffer enqueue];

        ASSERT(metalCmdBuffer);

        *queueSerialOut = serial;

        return metalCmdBuffer;
    }
}

void CommandQueue::onCommandBufferCommitted(id<MTLCommandBuffer> buf, uint64_t serial)
{
    std::lock_guard<std::mutex> lg(mLock);

    ANGLE_MTL_LOG("Committed MTLCommandBuffer %llu:%p", serial, buf);

    mCommittedBufferSerial.store(
        std::max(mCommittedBufferSerial.load(std::memory_order_relaxed), serial),
        std::memory_order_relaxed);
}

void CommandQueue::onCommandBufferCompleted(id<MTLCommandBuffer> buf, uint64_t serial)
{
    std::lock_guard<std::mutex> lg(mLock);

    ANGLE_MTL_LOG("Completed MTLCommandBuffer %llu:%p", serial, buf);

    if (mCompletedBufferSerial >= serial)
    {
        // Already handled.
        return;
    }

    while (!mMetalCmdBuffers.empty() && mMetalCmdBuffers.front().serial <= serial)
    {
        CmdBufferQueueEntry metalBufferEntry = mMetalCmdBuffers.front();
        ANGLE_UNUSED_VARIABLE(metalBufferEntry);
        ANGLE_MTL_LOG("Popped MTLCommandBuffer %llu:%p", metalBufferEntry.serial,
                      metalBufferEntry.buffer.get());

        mMetalCmdBuffers.pop_front();
    }

    mCompletedBufferSerial.store(
        std::max(mCompletedBufferSerial.load(std::memory_order_relaxed), serial),
        std::memory_order_relaxed);
}

// CommandBuffer implementation
CommandBuffer::CommandBuffer(CommandQueue *cmdQueue) : mCmdQueue(*cmdQueue) {}

CommandBuffer::~CommandBuffer()
{
    finish();
    cleanup();
}

bool CommandBuffer::valid() const
{
    std::lock_guard<std::mutex> lg(mLock);

    return validImpl();
}

void CommandBuffer::commit()
{
    std::lock_guard<std::mutex> lg(mLock);
    commitImpl();
}

void CommandBuffer::finish()
{
    commit();
    [get() waitUntilCompleted];
}

void CommandBuffer::present(id<CAMetalDrawable> presentationDrawable)
{
    [get() presentDrawable:presentationDrawable];
}

void CommandBuffer::setWriteDependency(const ResourceRef &resource)
{
    if (!resource)
    {
        return;
    }

    std::lock_guard<std::mutex> lg(mLock);

    if (!validImpl())
    {
        return;
    }

    resource->setUsedByCommandBufferWithQueueSerial(mQueueSerial, true);
}

void CommandBuffer::setReadDependency(const ResourceRef &resource)
{
    setReadDependency(resource.get());
}

void CommandBuffer::setReadDependency(Resource *resource)
{
    if (!resource)
    {
        return;
    }

    std::lock_guard<std::mutex> lg(mLock);

    if (!validImpl())
    {
        return;
    }

    resource->setUsedByCommandBufferWithQueueSerial(mQueueSerial, false);
}

void CommandBuffer::restart()
{
    uint64_t serial     = 0;
    auto metalCmdBuffer = mCmdQueue.makeMetalCommandBuffer(&serial);

    std::lock_guard<std::mutex> lg(mLock);

    set(metalCmdBuffer);
    mQueueSerial = serial;
    mCommitted   = false;

    for (std::string &marker : mDebugGroups)
    {
        pushDebugGroupImpl(marker);
    }

    ASSERT(metalCmdBuffer);
}

void CommandBuffer::insertDebugSign(const std::string &marker)
{
    mtl::CommandEncoder *currentEncoder = mActiveCommandEncoder;
    if (currentEncoder)
    {
        ANGLE_MTL_OBJC_SCOPE
        {
            auto label = cppLabelToObjC(marker);
            currentEncoder->insertDebugSign(label);
        }
    }
    else
    {
        mPendingDebugSigns.push_back(marker);
    }
}

void CommandBuffer::pushDebugGroup(const std::string &marker)
{
    // NOTE(hqle): to implement this
}

void CommandBuffer::popDebugGroup()
{
    // NOTE(hqle): to implement this
}

void CommandBuffer::queueEventSignal(const mtl::SharedEventRef &event, uint64_t value)
{
    std::lock_guard<std::mutex> lg(mLock);

    ASSERT(validImpl());

    if (mActiveCommandEncoder && mActiveCommandEncoder->getType() == CommandEncoder::RENDER)
    {
        // We cannot set event when there is an active render pass, defer the setting until the
        // pass end.
        mPendingSignalEvents.push_back({event, value});
    }
    else
    {
        setEventImpl(event, value);
    }
}

void CommandBuffer::serverWaitEvent(const mtl::SharedEventRef &event, uint64_t value)
{
    std::lock_guard<std::mutex> lg(mLock);
    ASSERT(validImpl());

    waitEventImpl(event, value);
}

/** private use only */
void CommandBuffer::set(id<MTLCommandBuffer> metalBuffer)
{
    ParentClass::set(metalBuffer);
}

void CommandBuffer::setActiveCommandEncoder(CommandEncoder *encoder)
{
    mActiveCommandEncoder = encoder;
    for (auto &marker : mPendingDebugSigns)
    {
        ANGLE_MTL_OBJC_SCOPE
        {
            auto label = cppLabelToObjC(marker);
            encoder->insertDebugSign(label);
        }
    }
    mPendingDebugSigns.clear();
}

void CommandBuffer::invalidateActiveCommandEncoder(CommandEncoder *encoder)
{
    if (mActiveCommandEncoder == encoder)
    {
        mActiveCommandEncoder = nullptr;

        // No active command encoder, we can safely encode event signalling now.
        setPendingEvents();
    }
}

void CommandBuffer::cleanup()
{
    mActiveCommandEncoder = nullptr;

    ParentClass::set(nil);
}

bool CommandBuffer::validImpl() const
{
    if (!ParentClass::valid())
    {
        return false;
    }

    return !mCommitted;
}

void CommandBuffer::commitImpl()
{
    if (!validImpl())
    {
        return;
    }

    // End the current encoder
    forceEndingCurrentEncoder();

    // Encoding any pending event's signalling.
    setPendingEvents();

    // Notify command queue
    mCmdQueue.onCommandBufferCommitted(get(), mQueueSerial);

    // Do the actual commit
    [get() commit];

    mCommitted = true;
}

void CommandBuffer::forceEndingCurrentEncoder()
{
    if (mActiveCommandEncoder)
    {
        mActiveCommandEncoder->endEncoding();
        mActiveCommandEncoder = nullptr;
    }
}

void CommandBuffer::setPendingEvents()
{
    for (const std::pair<mtl::SharedEventRef, uint64_t> &eventEntry : mPendingSignalEvents)
    {
        setEventImpl(eventEntry.first, eventEntry.second);
    }
    mPendingSignalEvents.clear();
}

void CommandBuffer::setEventImpl(const mtl::SharedEventRef &event, uint64_t value)
{
#if ANGLE_MTL_EVENT_AVAILABLE
    ASSERT(!mActiveCommandEncoder || mActiveCommandEncoder->getType() != CommandEncoder::RENDER);
    // For non-render command encoder, we can safely end it, so that we can encode a signal
    // event.
    forceEndingCurrentEncoder();

    [get() encodeSignalEvent:event value:value];
#else
    UNIMPLEMENTED();
    UNREACHABLE();
#endif  // #if ANGLE_MTL_EVENT_AVAILABLE
}

void CommandBuffer::waitEventImpl(const mtl::SharedEventRef &event, uint64_t value)
{
#if ANGLE_MTL_EVENT_AVAILABLE
    ASSERT(!mActiveCommandEncoder || mActiveCommandEncoder->getType() != CommandEncoder::RENDER);

    forceEndingCurrentEncoder();

    // Encoding any pending event's signalling.
    setPendingEvents();

    [get() encodeWaitForEvent:event value:value];
#else
    UNIMPLEMENTED();
    UNREACHABLE();
#endif  // #if ANGLE_MTL_EVENT_AVAILABLE
}

void CommandBuffer::pushDebugGroupImpl(const std::string &marker)
{
    ANGLE_MTL_OBJC_SCOPE
    {
        NSString *label = cppLabelToObjC(marker);
        [get() pushDebugGroup:label];

        if (mActiveCommandEncoder)
        {
            mActiveCommandEncoder->pushDebugGroup(label);
        }
    }
}

void CommandBuffer::popDebugGroupImpl()
{
    if (mActiveCommandEncoder)
    {
        mActiveCommandEncoder->popDebugGroup();
    }
    [get() popDebugGroup];
}

// CommandEncoder implementation
CommandEncoder::CommandEncoder(CommandBuffer *cmdBuffer, Type type)
    : mType(type), mCmdBuffer(*cmdBuffer)
{}

CommandEncoder::~CommandEncoder()
{
    reset();
}

void CommandEncoder::endEncoding()
{
    [get() endEncoding];
    reset();
}

void CommandEncoder::reset()
{
    ParentClass::reset();

    mCmdBuffer.invalidateActiveCommandEncoder(this);
}

void CommandEncoder::set(id<MTLCommandEncoder> metalCmdEncoder)
{
    ParentClass::set(metalCmdEncoder);

    // Set this as active encoder
    cmdBuffer().setActiveCommandEncoder(this);
}

CommandEncoder &CommandEncoder::markResourceBeingWrittenByGPU(const BufferRef &buffer)
{
    cmdBuffer().setWriteDependency(buffer);
    return *this;
}

CommandEncoder &CommandEncoder::markResourceBeingWrittenByGPU(const TextureRef &texture)
{
    cmdBuffer().setWriteDependency(texture);
    return *this;
}

void CommandEncoder::pushDebugGroup(NSString *label)
{
    // Default implementation
    [get() pushDebugGroup:label];
}

void CommandEncoder::popDebugGroup()
{
    // Default implementation
    [get() popDebugGroup];
}

void CommandEncoder::insertDebugSign(NSString *label)
{
    insertDebugSignImpl(label);
}

void CommandEncoder::insertDebugSignImpl(NSString *label)
{
    // Default implementation
    [get() insertDebugSignpost:label];
}

// RenderCommandEncoderShaderStates implementation
RenderCommandEncoderShaderStates::RenderCommandEncoderShaderStates()
{
    reset();
}

void RenderCommandEncoderShaderStates::reset()
{
    for (id<MTLBuffer> &buffer : buffers)
    {
        buffer = nil;
    }

    for (uint32_t &offset : bufferOffsets)
    {
        offset = 0;
    }

    for (id<MTLSamplerState> &sampler : samplers)
    {
        sampler = nil;
    }

    for (Optional<std::pair<float, float>> &lodClampRange : samplerLodClamps)
    {
        lodClampRange.reset();
    }

    for (id<MTLTexture> &texture : textures)
    {
        texture = nil;
    }
}

// RenderCommandEncoderStates implementation
RenderCommandEncoderStates::RenderCommandEncoderStates()
{
    reset();
}

void RenderCommandEncoderStates::reset()
{
    renderPipeline = nil;

    triangleFillMode = MTLTriangleFillModeFill;
    winding          = MTLWindingClockwise;
    cullMode         = MTLCullModeNone;

    depthStencilState = nil;
    depthBias = depthSlopeScale = depthClamp = 0;

    stencilFrontRef = stencilBackRef = 0;

    viewport.reset();
    scissorRect.reset();

    blendColor = {0, 0, 0, 0};

    for (RenderCommandEncoderShaderStates &shaderStates : perShaderStates)
    {
        shaderStates.reset();
    }

    visibilityResultMode         = MTLVisibilityResultModeDisabled;
    visibilityResultBufferOffset = 0;
}

// RenderCommandEncoder implemtation
RenderCommandEncoder::RenderCommandEncoder(CommandBuffer *cmdBuffer,
                                           const OcclusionQueryPool &queryPool)
    : CommandEncoder(cmdBuffer, RENDER), mOcclusionQueryPool(queryPool)
{
    ANGLE_MTL_OBJC_SCOPE
    {
        mCachedRenderPassDescObjC = [MTLRenderPassDescriptor renderPassDescriptor];
    }

    static_assert(sizeof(uint8_t) == sizeof(CmdType), "CmdType was expected to be 8 bit");
    for (gl::ShaderType shaderType : gl::AllShaderTypes())
    {
        mSetBufferCmds[shaderType]  = static_cast<uint8_t>(CmdType::Invalid);
        mSetBytesCmds[shaderType]   = static_cast<uint8_t>(CmdType::Invalid);
        mSetTextureCmds[shaderType] = static_cast<uint8_t>(CmdType::Invalid);
        mSetSamplerCmds[shaderType] = static_cast<uint8_t>(CmdType::Invalid);
    }

    mSetBufferCmds[gl::ShaderType::Vertex]   = static_cast<uint8_t>(CmdType::SetVertexBuffer);
    mSetBufferCmds[gl::ShaderType::Fragment] = static_cast<uint8_t>(CmdType::SetFragmentBuffer);

    mSetBufferOffsetCmds[gl::ShaderType::Vertex] =
        static_cast<uint8_t>(CmdType::SetVertexBufferOffset);
    mSetBufferOffsetCmds[gl::ShaderType::Fragment] =
        static_cast<uint8_t>(CmdType::SetFragmentBufferOffset);

    mSetBytesCmds[gl::ShaderType::Vertex]   = static_cast<uint8_t>(CmdType::SetVertexBytes);
    mSetBytesCmds[gl::ShaderType::Fragment] = static_cast<uint8_t>(CmdType::SetFragmentBytes);

    mSetTextureCmds[gl::ShaderType::Vertex]   = static_cast<uint8_t>(CmdType::SetVertexTexture);
    mSetTextureCmds[gl::ShaderType::Fragment] = static_cast<uint8_t>(CmdType::SetFragmentTexture);

    mSetSamplerCmds[gl::ShaderType::Vertex] = static_cast<uint8_t>(CmdType::SetVertexSamplerState);
    mSetSamplerCmds[gl::ShaderType::Fragment] =
        static_cast<uint8_t>(CmdType::SetFragmentSamplerState);
}
RenderCommandEncoder::~RenderCommandEncoder() {}

void RenderCommandEncoder::reset()
{
    CommandEncoder::reset();
    mRecording = false;
    mCommands.clear();
}

void RenderCommandEncoder::finalizeLoadStoreAction(
    MTLRenderPassAttachmentDescriptor *objCRenderPassAttachment)
{
    if (!objCRenderPassAttachment.texture)
    {
        objCRenderPassAttachment.loadAction     = MTLLoadActionDontCare;
        objCRenderPassAttachment.storeAction    = MTLStoreActionDontCare;
        objCRenderPassAttachment.resolveTexture = nil;
        return;
    }

    if (objCRenderPassAttachment.resolveTexture)
    {
        if (objCRenderPassAttachment.storeAction == MTLStoreActionStore)
        {
            // NOTE(hqle): Currently if the store action with implicit MS texture is MTLStoreAction,
            // it is automatically convert to store and resolve action. It might introduce
            // unnecessary overhead.
            // Consider an improvement such as only store the MS texture, and resolve only at
            // the end of real render pass (not render pass the was interrupted by compute pass)
            // or before glBlitFramebuffer operation starts.
            objCRenderPassAttachment.storeAction = MTLStoreActionStoreAndMultisampleResolve;
        }
        else if (objCRenderPassAttachment.storeAction == MTLStoreActionDontCare)
        {
            // Ignore resolve texture if the store action is not a resolve action.
            objCRenderPassAttachment.resolveTexture = nil;
        }
    }

    if (objCRenderPassAttachment.storeAction == MTLStoreActionUnknown)
    {
        // If storeAction hasn't been set for this attachment, we set to dontcare.
        objCRenderPassAttachment.storeAction = MTLStoreActionDontCare;
    }
}

void RenderCommandEncoder::endEncoding()
{
    endEncodingImpl(true);
}

void RenderCommandEncoder::endEncodingImpl(bool considerDiscardSimulation)
{
    if (!valid())
        return;

    // Last minute correcting the store options.
    MTLRenderPassDescriptor *objCRenderPassDesc = mCachedRenderPassDescObjC.get();
    for (uint32_t i = 0; i < mRenderPassDesc.numColorAttachments; ++i)
    {
        // Update store action set between restart() and endEncoding()
        objCRenderPassDesc.colorAttachments[i].storeAction =
            mRenderPassDesc.colorAttachments[i].storeAction;
        finalizeLoadStoreAction(objCRenderPassDesc.colorAttachments[i]);
    }

    // Update store action set between restart() and endEncoding()
    objCRenderPassDesc.depthAttachment.storeAction = mRenderPassDesc.depthAttachment.storeAction;
    finalizeLoadStoreAction(objCRenderPassDesc.depthAttachment);

    // Update store action set between restart() and endEncoding()
    objCRenderPassDesc.stencilAttachment.storeAction =
        mRenderPassDesc.stencilAttachment.storeAction;
    finalizeLoadStoreAction(objCRenderPassDesc.stencilAttachment);

    // Set visibility result buffer
    if (mOcclusionQueryPool.getNumRenderPassAllocatedQueries())
    {
        objCRenderPassDesc.visibilityResultBuffer =
            mOcclusionQueryPool.getRenderPassVisibilityPoolBuffer()->get();
    }
    else
    {
        objCRenderPassDesc.visibilityResultBuffer = nil;
    }

    // Encode the actual encoder
    encodeMetalEncoder();

    CommandEncoder::endEncoding();

#if ANGLE_MTL_SIMULATE_DISCARD_FRAMEBUFFER
    if (considerDiscardSimulation)
    {
        simulateDiscardFramebuffer();
    }
#endif

    // reset state
    mRenderPassDesc = RenderPassDesc();
    mStateCache.reset();
}

inline void RenderCommandEncoder::initWriteDependency(const TextureRef &texture)
{
    if (texture)
    {
        cmdBuffer().setWriteDependency(texture);
    }
}

void RenderCommandEncoder::simulateDiscardFramebuffer()
{
    // Simulate true framebuffer discard operation by clearing the framebuffer
#if ANGLE_MTL_SIMULATE_DISCARD_FRAMEBUFFER
    std::random_device rd;   // Will be used to obtain a seed for the random number engine
    std::mt19937 gen(rd());  // Standard mersenne_twister_engine seeded with rd()
    std::uniform_real_distribution<float> dis(0.0, 1.0f);
    bool hasDiscard = false;
    for (uint32_t i = 0; i < mRenderPassDesc.numColorAttachments; ++i)
    {
        if (mRenderPassDesc.colorAttachments[i].storeAction == MTLStoreActionDontCare)
        {
            hasDiscard                                     = true;
            mRenderPassDesc.colorAttachments[i].loadAction = MTLLoadActionClear;
            mRenderPassDesc.colorAttachments[i].clearColor =
                MTLClearColorMake(dis(gen), dis(gen), dis(gen), dis(gen));
        }
        else
        {
            mRenderPassDesc.colorAttachments[i].loadAction = MTLLoadActionLoad;
        }
    }

    if (mRenderPassDesc.depthAttachment.storeAction == MTLStoreActionDontCare)
    {
        hasDiscard                                 = true;
        mRenderPassDesc.depthAttachment.loadAction = MTLLoadActionClear;
        mRenderPassDesc.depthAttachment.clearDepth = dis(gen);
    }
    else
    {
        mRenderPassDesc.depthAttachment.loadAction = MTLLoadActionLoad;
    }

    if (mRenderPassDesc.stencilAttachment.storeAction == MTLStoreActionDontCare)
    {
        hasDiscard                                     = true;
        mRenderPassDesc.stencilAttachment.loadAction   = MTLLoadActionClear;
        mRenderPassDesc.stencilAttachment.clearStencil = rand();
    }
    else
    {
        mRenderPassDesc.stencilAttachment.loadAction = MTLLoadActionLoad;
    }

    if (hasDiscard)
    {
        auto tmpDesc = mRenderPassDesc;
        restart(tmpDesc);
        endEncodingImpl(false);
    }
#endif  // ANGLE_MTL_SIMULATE_DISCARD_FRAMEBUFFER
}

void RenderCommandEncoder::encodeMetalEncoder()
{
    ANGLE_MTL_OBJC_SCOPE
    {
        ANGLE_MTL_LOG("Creating new render command encoder with desc: %@",
                      [mCachedRenderPassDescObjC description]);

        id<MTLRenderCommandEncoder> metalCmdEncoder =
            [cmdBuffer().get() renderCommandEncoderWithDescriptor:mCachedRenderPassDescObjC];

        set(metalCmdEncoder);

        // Verify that it was created successfully
        ASSERT(get());

        // Work-around driver bug on iOS devices: stencil must be explicitly set to zero
        // even if the doc says the default value is already zero.
        [metalCmdEncoder setStencilReferenceValue:0];

        if (mLabel)
        {
            metalCmdEncoder.label = mLabel;
        }

        while (mCommands.good())
        {
            auto cmdType               = mCommands.fetch<CmdType>();
            CommandEncoderFunc encoder = gCommandEncoders[static_cast<int>(cmdType)];
            encoder(metalCmdEncoder, &mCommands);
        }

        mCommands.clear();
    }
}

RenderCommandEncoder &RenderCommandEncoder::restart(const RenderPassDesc &desc)
{
    if (valid())
    {
        if (mRenderPassDesc == desc)
        {
            // no change, skip
            return *this;
        }

        // finish current encoder
        endEncoding();
    }

    if (!cmdBuffer().valid())
    {
        reset();
        return *this;
    }

    mRenderPassDesc = desc;
    mRecording      = true;
    mHasDrawCalls   = false;

    // mask writing dependency & set appropriate store options
    for (uint32_t i = 0; i < mRenderPassDesc.numColorAttachments; ++i)
    {
        initWriteDependency(mRenderPassDesc.colorAttachments[i].texture());
    }

    initWriteDependency(mRenderPassDesc.depthAttachment.texture());

    initWriteDependency(mRenderPassDesc.stencilAttachment.texture());

    // Convert to Objective-C descriptor
    mRenderPassDesc.convertToMetalDesc(mCachedRenderPassDescObjC);

    // The actual Objective-C encoder will be created later in endEncoding(), we do so in order
    // to be able to sort the commands or do the preprocessing before the actual encoding.

    // Since we defer the native encoder creation, we need to explicitly tell command buffer that
    // this object is the active encoder:
    cmdBuffer().setActiveCommandEncoder(this);

    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::setRenderPipelineState(id<MTLRenderPipelineState> state)
{
    if (mStateCache.renderPipeline == state)
    {
        return *this;
    }
    mStateCache.renderPipeline = state;

    mCommands.push(CmdType::SetRenderPipelineState).push([state ANGLE_MTL_RETAIN]);

    return *this;
}
RenderCommandEncoder &RenderCommandEncoder::setTriangleFillMode(MTLTriangleFillMode mode)
{
    if (mStateCache.triangleFillMode == mode)
    {
        return *this;
    }
    mStateCache.triangleFillMode = mode;

    mCommands.push(CmdType::SetTriangleFillMode).push(mode);

    return *this;
}
RenderCommandEncoder &RenderCommandEncoder::setFrontFacingWinding(MTLWinding winding)
{
    if (mStateCache.winding == winding)
    {
        return *this;
    }
    mStateCache.winding = winding;

    mCommands.push(CmdType::SetFrontFacingWinding).push(winding);

    return *this;
}
RenderCommandEncoder &RenderCommandEncoder::setCullMode(MTLCullMode mode)
{
    if (mStateCache.cullMode == mode)
    {
        return *this;
    }
    mStateCache.cullMode = mode;

    mCommands.push(CmdType::SetCullMode).push(mode);

    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::setDepthStencilState(id<MTLDepthStencilState> state)
{
    if (mStateCache.depthStencilState == state)
    {
        return *this;
    }
    mStateCache.depthStencilState = state;

    mCommands.push(CmdType::SetDepthStencilState).push([state ANGLE_MTL_RETAIN]);

    return *this;
}
RenderCommandEncoder &RenderCommandEncoder::setDepthBias(float depthBias,
                                                         float slopeScale,
                                                         float clamp)
{
    if (mStateCache.depthBias == depthBias && mStateCache.depthSlopeScale == slopeScale &&
        mStateCache.depthClamp == clamp)
    {
        return *this;
    }
    mStateCache.depthBias       = depthBias;
    mStateCache.depthSlopeScale = slopeScale;
    mStateCache.depthClamp      = clamp;

    mCommands.push(CmdType::SetDepthBias).push(depthBias).push(slopeScale).push(clamp);

    return *this;
}
RenderCommandEncoder &RenderCommandEncoder::setStencilRefVals(uint32_t frontRef, uint32_t backRef)
{
    // Metal has some bugs when reference values are larger than 0xff
    ASSERT(frontRef == (frontRef & kStencilMaskAll));
    ASSERT(backRef == (backRef & kStencilMaskAll));

    if (mStateCache.stencilFrontRef == frontRef && mStateCache.stencilBackRef == backRef)
    {
        return *this;
    }
    mStateCache.stencilFrontRef = frontRef;
    mStateCache.stencilBackRef  = backRef;

    mCommands.push(CmdType::SetStencilRefVals).push(frontRef).push(backRef);

    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::setStencilRefVal(uint32_t ref)
{
    return setStencilRefVals(ref, ref);
}

RenderCommandEncoder &RenderCommandEncoder::setViewport(const MTLViewport &viewport)
{
    if (mStateCache.viewport.valid() && mStateCache.viewport.value() == viewport)
    {
        return *this;
    }
    mStateCache.viewport = viewport;

    mCommands.push(CmdType::SetViewport).push(viewport);

    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::setScissorRect(const MTLScissorRect &rect)
{
    if (mStateCache.scissorRect.valid() && mStateCache.scissorRect.value() == rect)
    {
        return *this;
    }
    mStateCache.scissorRect = rect;

    mCommands.push(CmdType::SetScissorRect).push(rect);

    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::setBlendColor(float r, float g, float b, float a)
{
    if (mStateCache.blendColor[0] == r && mStateCache.blendColor[1] == g &&
        mStateCache.blendColor[2] == b && mStateCache.blendColor[3] == a)
    {
        return *this;
    }
    mStateCache.blendColor[0] = r;
    mStateCache.blendColor[1] = g;
    mStateCache.blendColor[2] = b;
    mStateCache.blendColor[3] = a;

    mCommands.push(CmdType::SetBlendColor).push(r).push(g).push(b).push(a);

    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::setBuffer(gl::ShaderType shaderType,
                                                      const BufferRef &buffer,
                                                      uint32_t offset,
                                                      uint32_t index)
{
    if (index >= kMaxShaderBuffers)
    {
        return *this;
    }

    cmdBuffer().setReadDependency(buffer);

    id<MTLBuffer> mtlBuffer = (buffer ? buffer->get() : nil);

    return commonSetBuffer(shaderType, mtlBuffer, offset, index);
}

RenderCommandEncoder &RenderCommandEncoder::setBufferForWrite(gl::ShaderType shaderType,
                                                              const BufferRef &buffer,
                                                              uint32_t offset,
                                                              uint32_t index)
{
    if (index >= kMaxShaderBuffers)
    {
        return *this;
    }

    cmdBuffer().setWriteDependency(buffer);

    id<MTLBuffer> mtlBuffer = (buffer ? buffer->get() : nil);

    return commonSetBuffer(shaderType, mtlBuffer, offset, index);
}

RenderCommandEncoder &RenderCommandEncoder::commonSetBuffer(gl::ShaderType shaderType,
                                                            id<MTLBuffer> mtlBuffer,
                                                            uint32_t offset,
                                                            uint32_t index)
{
    RenderCommandEncoderShaderStates &shaderStates = mStateCache.perShaderStates[shaderType];
    if (shaderStates.buffers[index] == mtlBuffer)
    {
        if (shaderStates.bufferOffsets[index] == offset)
        {
            return *this;
        }

        // If buffer already bound but with different offset, then update the offer only.
        shaderStates.bufferOffsets[index] = offset;

        mCommands.push(static_cast<CmdType>(mSetBufferOffsetCmds[shaderType]))
            .push(offset)
            .push(index);

        return *this;
    }

    shaderStates.buffers[index]       = mtlBuffer;
    shaderStates.bufferOffsets[index] = offset;

    mCommands.push(static_cast<CmdType>(mSetBufferCmds[shaderType]))
        .push([mtlBuffer ANGLE_MTL_RETAIN])
        .push(offset)
        .push(index);

    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::setBytes(gl::ShaderType shaderType,
                                                     const uint8_t *bytes,
                                                     size_t size,
                                                     uint32_t index)
{
    if (index >= kMaxShaderBuffers)
    {
        return *this;
    }

    RenderCommandEncoderShaderStates &shaderStates = mStateCache.perShaderStates[shaderType];
    shaderStates.buffers[index]                    = nil;
    shaderStates.bufferOffsets[index]              = 0;

    mCommands.push(static_cast<CmdType>(mSetBytesCmds[shaderType]))
        .push(size)
        .push(bytes, size)
        .push(index);

    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::setSamplerState(gl::ShaderType shaderType,
                                                            id<MTLSamplerState> state,
                                                            float lodMinClamp,
                                                            float lodMaxClamp,
                                                            uint32_t index)
{
    if (index >= kMaxShaderSamplers)
    {
        return *this;
    }

    RenderCommandEncoderShaderStates &shaderStates = mStateCache.perShaderStates[shaderType];
    if (shaderStates.samplers[index] == state && shaderStates.samplerLodClamps[index].valid())
    {
        const std::pair<float, float> &currentLodClampRange =
            shaderStates.samplerLodClamps[index].value();
        if (currentLodClampRange.first == lodMinClamp && currentLodClampRange.second == lodMaxClamp)
        {
            return *this;
        }
    }

    shaderStates.samplers[index]         = state;
    shaderStates.samplerLodClamps[index] = {lodMinClamp, lodMaxClamp};

    mCommands.push(static_cast<CmdType>(mSetSamplerCmds[shaderType]))
        .push([state ANGLE_MTL_RETAIN])
        .push(lodMinClamp)
        .push(lodMaxClamp)
        .push(index);

    return *this;
}
RenderCommandEncoder &RenderCommandEncoder::setTexture(gl::ShaderType shaderType,
                                                       const TextureRef &texture,
                                                       uint32_t index)
{
    if (index >= kMaxShaderSamplers)
    {
        return *this;
    }

    cmdBuffer().setReadDependency(texture);

    id<MTLTexture> mtlTexture = (texture ? texture->get() : nil);

    RenderCommandEncoderShaderStates &shaderStates = mStateCache.perShaderStates[shaderType];
    if (shaderStates.textures[index] == mtlTexture)
    {
        return *this;
    }
    shaderStates.textures[index] = mtlTexture;

    mCommands.push(static_cast<CmdType>(mSetTextureCmds[shaderType]))
        .push([mtlTexture ANGLE_MTL_RETAIN])
        .push(index);

    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::draw(MTLPrimitiveType primitiveType,
                                                 uint32_t vertexStart,
                                                 uint32_t vertexCount)
{
    mHasDrawCalls = true;
    mCommands.push(CmdType::Draw).push(primitiveType).push(vertexStart).push(vertexCount);

    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::drawInstanced(MTLPrimitiveType primitiveType,
                                                          uint32_t vertexStart,
                                                          uint32_t vertexCount,
                                                          uint32_t instances)
{
    mHasDrawCalls = true;
    mCommands.push(CmdType::DrawInstanced)
        .push(primitiveType)
        .push(vertexStart)
        .push(vertexCount)
        .push(instances);

    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::drawIndexed(MTLPrimitiveType primitiveType,
                                                        uint32_t indexCount,
                                                        MTLIndexType indexType,
                                                        const BufferRef &indexBuffer,
                                                        size_t bufferOffset)
{
    if (!indexBuffer)
    {
        return *this;
    }

    mHasDrawCalls = true;
    cmdBuffer().setReadDependency(indexBuffer);

    mCommands.push(CmdType::DrawIndexed)
        .push(primitiveType)
        .push(indexCount)
        .push(indexType)
        .push([indexBuffer->get() ANGLE_MTL_RETAIN])
        .push(bufferOffset);

    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::drawIndexedInstanced(MTLPrimitiveType primitiveType,
                                                                 uint32_t indexCount,
                                                                 MTLIndexType indexType,
                                                                 const BufferRef &indexBuffer,
                                                                 size_t bufferOffset,
                                                                 uint32_t instances)
{
    if (!indexBuffer)
    {
        return *this;
    }

    mHasDrawCalls = true;
    cmdBuffer().setReadDependency(indexBuffer);

    mCommands.push(CmdType::DrawIndexedInstanced)
        .push(primitiveType)
        .push(indexCount)
        .push(indexType)
        .push([indexBuffer->get() ANGLE_MTL_RETAIN])
        .push(bufferOffset)
        .push(instances);

    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::drawIndexedInstancedBaseVertex(
    MTLPrimitiveType primitiveType,
    uint32_t indexCount,
    MTLIndexType indexType,
    const BufferRef &indexBuffer,
    size_t bufferOffset,
    uint32_t instances,
    uint32_t baseVertex)
{
    if (!indexBuffer)
    {
        return *this;
    }

    mHasDrawCalls = true;
    cmdBuffer().setReadDependency(indexBuffer);

    mCommands.push(CmdType::DrawIndexedInstancedBaseVertex)
        .push(primitiveType)
        .push(indexCount)
        .push(indexType)
        .push([indexBuffer->get() ANGLE_MTL_RETAIN])
        .push(bufferOffset)
        .push(instances)
        .push(baseVertex);

    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::setVisibilityResultMode(MTLVisibilityResultMode mode,
                                                                    size_t offset)
{
    if (mStateCache.visibilityResultMode == mode &&
        mStateCache.visibilityResultBufferOffset == offset)
    {
        return *this;
    }
    mStateCache.visibilityResultMode         = mode;
    mStateCache.visibilityResultBufferOffset = offset;

    mCommands.push(CmdType::SetVisibilityResultMode).push(mode).push(offset);
    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::useResource(const BufferRef &resource,
                                                        MTLResourceUsage usage,
                                                        mtl::RenderStages states)
{
    if (!resource)
    {
        return *this;
    }

    cmdBuffer().setReadDependency(resource);

    mCommands.push(CmdType::UseResource)
        .push([resource->get() ANGLE_MTL_RETAIN])
        .push(usage)
        .push(states);

    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::memoryBarrierWithResource(const BufferRef &resource,
                                                                      mtl::RenderStages after,
                                                                      mtl::RenderStages before)
{
    if (!resource)
    {
        return *this;
    }

    cmdBuffer().setWriteDependency(resource);

    mCommands.push(CmdType::MemoryBarrierWithResource)
        .push([resource->get() ANGLE_MTL_RETAIN])
        .push(after)
        .push(before);

    return *this;
}

void RenderCommandEncoder::insertDebugSignImpl(NSString *label)
{
    // Defer the insertion until endEncoding()
    mCommands.push(CmdType::InsertDebugsign).push([label ANGLE_MTL_RETAIN]);
}

void RenderCommandEncoder::pushDebugGroup(NSString *label)
{
    // Defer the insertion until endEncoding()
    mCommands.push(CmdType::PushDebugGroup).push([label ANGLE_MTL_RETAIN]);
}
void RenderCommandEncoder::popDebugGroup()
{
    mCommands.push(CmdType::PopDebugGroup);
}

RenderCommandEncoder &RenderCommandEncoder::setColorStoreAction(MTLStoreAction action,
                                                                uint32_t colorAttachmentIndex)
{
    if (colorAttachmentIndex >= mRenderPassDesc.numColorAttachments)
    {
        return *this;
    }

    // We only store the options, will defer the actual setting until the encoder finishes
    mRenderPassDesc.colorAttachments[colorAttachmentIndex].storeAction = action;

    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::setColorStoreAction(MTLStoreAction action)
{
    for (uint32_t i = 0; i < mRenderPassDesc.numColorAttachments; ++i)
    {
        setColorStoreAction(action, i);
    }
    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::setDepthStencilStoreAction(
    MTLStoreAction depthStoreAction,
    MTLStoreAction stencilStoreAction)
{
    // We only store the options, will defer the actual setting until the encoder finishes
    mRenderPassDesc.depthAttachment.storeAction   = depthStoreAction;
    mRenderPassDesc.stencilAttachment.storeAction = stencilStoreAction;

    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::setDepthStoreAction(MTLStoreAction action)
{
    // We only store the options, will defer the actual setting until the encoder finishes
    mRenderPassDesc.depthAttachment.storeAction = action;

    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::setStencilStoreAction(MTLStoreAction action)
{
    // We only store the options, will defer the actual setting until the encoder finishes
    mRenderPassDesc.stencilAttachment.storeAction = action;

    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::setStoreAction(MTLStoreAction action)
{
    setColorStoreAction(action);
    setDepthStencilStoreAction(action, action);
    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::setColorLoadAction(MTLLoadAction action,
                                                               const MTLClearColor &clearValue,
                                                               uint32_t colorAttachmentIndex)
{
    ASSERT(!hasDrawCalls());
    if (mCachedRenderPassDescObjC.get().colorAttachments[colorAttachmentIndex].texture)
    {
        mCachedRenderPassDescObjC.get().colorAttachments[colorAttachmentIndex].loadAction = action;
        mCachedRenderPassDescObjC.get().colorAttachments[colorAttachmentIndex].clearColor =
            clearValue;
    }
    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::setDepthLoadAction(MTLLoadAction action,
                                                               double clearVal)
{
    ASSERT(!hasDrawCalls());
    if (mCachedRenderPassDescObjC.get().depthAttachment.texture)
    {
        mCachedRenderPassDescObjC.get().depthAttachment.loadAction = action;
        mCachedRenderPassDescObjC.get().depthAttachment.clearDepth = clearVal;
    }
    return *this;
}

RenderCommandEncoder &RenderCommandEncoder::setStencilLoadAction(MTLLoadAction action,
                                                                 uint32_t clearVal)
{
    ASSERT(!hasDrawCalls());
    if (mCachedRenderPassDescObjC.get().stencilAttachment.texture)
    {
        mCachedRenderPassDescObjC.get().stencilAttachment.loadAction   = action;
        mCachedRenderPassDescObjC.get().stencilAttachment.clearStencil = clearVal;
    }
    return *this;
}

void RenderCommandEncoder::setLabel(NSString *label)
{
    mLabel.retainAssign(label);
}

// BlitCommandEncoder
BlitCommandEncoder::BlitCommandEncoder(CommandBuffer *cmdBuffer) : CommandEncoder(cmdBuffer, BLIT)
{}

BlitCommandEncoder::~BlitCommandEncoder() {}

BlitCommandEncoder &BlitCommandEncoder::restart()
{
    ANGLE_MTL_OBJC_SCOPE
    {
        if (valid())
        {
            // no change, skip
            return *this;
        }

        if (!cmdBuffer().valid())
        {
            reset();
            return *this;
        }

        // Create objective C object
        set([cmdBuffer().get() blitCommandEncoder]);

        // Verify that it was created successfully
        ASSERT(get());

        return *this;
    }
}

BlitCommandEncoder &BlitCommandEncoder::copyBuffer(const BufferRef &src,
                                                   size_t srcOffset,
                                                   const BufferRef &dst,
                                                   size_t dstOffset,
                                                   size_t size)
{
    if (!src || !dst)
    {
        return *this;
    }

    cmdBuffer().setReadDependency(src);
    cmdBuffer().setWriteDependency(dst);

    [get() copyFromBuffer:src->get()
             sourceOffset:srcOffset
                 toBuffer:dst->get()
        destinationOffset:dstOffset
                     size:size];

    return *this;
}

BlitCommandEncoder &BlitCommandEncoder::copyBufferToTexture(const BufferRef &src,
                                                            size_t srcOffset,
                                                            size_t srcBytesPerRow,
                                                            size_t srcBytesPerImage,
                                                            MTLSize srcSize,
                                                            const TextureRef &dst,
                                                            uint32_t dstSlice,
                                                            MipmapNativeLevel dstLevel,
                                                            MTLOrigin dstOrigin,
                                                            MTLBlitOption blitOption)
{
    if (!src || !dst)
    {
        return *this;
    }

    cmdBuffer().setReadDependency(src);
    cmdBuffer().setWriteDependency(dst);

    [get() copyFromBuffer:src->get()
               sourceOffset:srcOffset
          sourceBytesPerRow:srcBytesPerRow
        sourceBytesPerImage:srcBytesPerImage
                 sourceSize:srcSize
                  toTexture:dst->get()
           destinationSlice:dstSlice
           destinationLevel:dstLevel.get()
          destinationOrigin:dstOrigin
                    options:blitOption];

    return *this;
}

BlitCommandEncoder &BlitCommandEncoder::copyTextureToBuffer(const TextureRef &src,
                                                            uint32_t srcSlice,
                                                            MipmapNativeLevel srcLevel,
                                                            MTLOrigin srcOrigin,
                                                            MTLSize srcSize,
                                                            const BufferRef &dst,
                                                            size_t dstOffset,
                                                            size_t dstBytesPerRow,
                                                            size_t dstBytesPerImage,
                                                            MTLBlitOption blitOption)
{

    if (!src || !dst)
    {
        return *this;
    }

    cmdBuffer().setReadDependency(src);
    cmdBuffer().setWriteDependency(dst);

    [get() copyFromTexture:src->get()
                     sourceSlice:srcSlice
                     sourceLevel:srcLevel.get()
                    sourceOrigin:srcOrigin
                      sourceSize:srcSize
                        toBuffer:dst->get()
               destinationOffset:dstOffset
          destinationBytesPerRow:dstBytesPerRow
        destinationBytesPerImage:dstBytesPerImage
                         options:blitOption];

    return *this;
}

BlitCommandEncoder &BlitCommandEncoder::copyTexture(const TextureRef &src,
                                                    uint32_t srcStartSlice,
                                                    MipmapNativeLevel srcStartLevel,
                                                    const TextureRef &dst,
                                                    uint32_t dstStartSlice,
                                                    MipmapNativeLevel dstStartLevel,
                                                    uint32_t sliceCount,
                                                    uint32_t levelCount)
{
    if (!src || !dst)
    {
        return *this;
    }

    cmdBuffer().setReadDependency(src);
    cmdBuffer().setWriteDependency(dst);

    MTLOrigin origin = MTLOriginMake(0, 0, 0);
    for (uint32_t slice = 0; slice < sliceCount; ++slice)
    {
        uint32_t srcSlice = srcStartSlice + slice;
        uint32_t dstSlice = dstStartSlice + slice;
        for (uint32_t level = 0; level < levelCount; ++level)
        {
            MipmapNativeLevel srcLevel = srcStartLevel + level;
            MipmapNativeLevel dstLevel = dstStartLevel + level;
            MTLSize srcSize =
                MTLSizeMake(src->width(srcLevel), src->height(srcLevel), src->depth(srcLevel));

            [get() copyFromTexture:src->get()
                       sourceSlice:srcSlice
                       sourceLevel:srcLevel.get()
                      sourceOrigin:origin
                        sourceSize:srcSize
                         toTexture:dst->get()
                  destinationSlice:dstSlice
                  destinationLevel:dstLevel.get()
                 destinationOrigin:origin];
        }
    }

    return *this;
}

BlitCommandEncoder &BlitCommandEncoder::fillBuffer(const BufferRef &buffer,
                                                   NSRange range,
                                                   uint8_t value)
{
    if (!buffer)
    {
        return *this;
    }

    [get() fillBuffer:buffer->get() range:range value:value];
    return *this;
}

BlitCommandEncoder &BlitCommandEncoder::copyTexture(const TextureRef &src,
                                                    uint32_t srcStartSlice,
                                                    uint32_t srcStartLevel,
                                                    const TextureRef &dst,
                                                    uint32_t dstStartSlice,
                                                    uint32_t dstStartLevel,
                                                    uint32_t sliceCount,
                                                    uint32_t levelCount)
{
    if (!src || !dst)
    {
        return *this;
    }

    cmdBuffer().setReadDependency(src);
    cmdBuffer().setWriteDependency(dst);

#if defined(__IPHONE_13_0) || defined(__MAC_10_15)
    if (ANGLE_APPLE_AVAILABLE_XCI(10.15, 13.0, 13.0))
    {
        [get() copyFromTexture:src->get()
                   sourceSlice:srcStartSlice
                   sourceLevel:srcStartLevel
                     toTexture:dst->get()
              destinationSlice:dstStartSlice
              destinationLevel:dstStartLevel
                    sliceCount:sliceCount
                    levelCount:levelCount];
    }
    else
#endif
    {
        MTLOrigin origin = MTLOriginMake(0, 0, 0);
        for (uint32_t slice = 0; slice < sliceCount; ++slice)
        {
            uint32_t srcSlice = srcStartSlice + slice;
            uint32_t dstSlice = dstStartSlice + slice;
            for (uint32_t level = 0; level < levelCount; ++level)
            {
                mtl::MipmapNativeLevel srcLevel = mtl::MipmapNativeLevel(srcStartLevel + level);
                uint32_t dstLevel = dstStartLevel + level;
                MTLSize srcSize =
                    MTLSizeMake(src->width(srcLevel), src->height(srcLevel), src->depth(srcLevel));

                [get() copyFromTexture:src->get()
                           sourceSlice:srcSlice
                           sourceLevel:srcLevel.get()
                          sourceOrigin:origin
                            sourceSize:srcSize
                             toTexture:dst->get()
                      destinationSlice:dstSlice
                      destinationLevel:dstLevel
                     destinationOrigin:origin];
            }
        }
    }

    return *this;
}

BlitCommandEncoder &BlitCommandEncoder::generateMipmapsForTexture(const TextureRef &texture)
{
    if (!texture)
    {
        return *this;
    }

    cmdBuffer().setWriteDependency(texture);
    [get() generateMipmapsForTexture:texture->get()];

    return *this;
}
BlitCommandEncoder &BlitCommandEncoder::synchronizeResource(const BufferRef &buffer)
{
    if (!buffer)
    {
        return *this;
    }

#if TARGET_OS_OSX || TARGET_OS_MACCATALYST
    // Only MacOS has separated storage for resource on CPU and GPU and needs explicit
    // synchronization
    cmdBuffer().setReadDependency(buffer);
    [get() synchronizeResource:buffer->get()];
#endif
    return *this;
}
BlitCommandEncoder &BlitCommandEncoder::synchronizeResource(const TextureRef &texture)
{
    if (!texture)
    {
        return *this;
    }

#if TARGET_OS_OSX || TARGET_OS_MACCATALYST
    // Only MacOS has separated storage for resource on CPU and GPU and needs explicit
    // synchronization
    cmdBuffer().setReadDependency(texture);
    if (texture->get().parentTexture)
    {
        [get() synchronizeResource:texture->get().parentTexture];
    }
    else
    {
        [get() synchronizeResource:texture->get()];
    }
#endif
    return *this;
}

// ComputeCommandEncoder implementation
ComputeCommandEncoder::ComputeCommandEncoder(CommandBuffer *cmdBuffer)
    : CommandEncoder(cmdBuffer, COMPUTE)
{}
ComputeCommandEncoder::~ComputeCommandEncoder() {}

ComputeCommandEncoder &ComputeCommandEncoder::restart()
{
    ANGLE_MTL_OBJC_SCOPE
    {
        if (valid())
        {
            // no change, skip
            return *this;
        }

        if (!cmdBuffer().valid())
        {
            reset();
            return *this;
        }

        // Create objective C object
        set([cmdBuffer().get() computeCommandEncoder]);

        // Verify that it was created successfully
        ASSERT(get());

        return *this;
    }
}

ComputeCommandEncoder &ComputeCommandEncoder::setComputePipelineState(
    id<MTLComputePipelineState> state)
{
    [get() setComputePipelineState:state];
    return *this;
}

ComputeCommandEncoder &ComputeCommandEncoder::setBuffer(const BufferRef &buffer,
                                                        uint32_t offset,
                                                        uint32_t index)
{
    if (index >= kMaxShaderBuffers)
    {
        return *this;
    }

    cmdBuffer().setReadDependency(buffer);

    [get() setBuffer:(buffer ? buffer->get() : nil) offset:offset atIndex:index];

    return *this;
}

ComputeCommandEncoder &ComputeCommandEncoder::setBufferForWrite(const BufferRef &buffer,
                                                                uint32_t offset,
                                                                uint32_t index)
{
    if (index >= kMaxShaderBuffers)
    {
        return *this;
    }

    cmdBuffer().setWriteDependency(buffer);
    return setBuffer(buffer, offset, index);
}

ComputeCommandEncoder &ComputeCommandEncoder::setBytes(const uint8_t *bytes,
                                                       size_t size,
                                                       uint32_t index)
{
    if (index >= kMaxShaderBuffers)
    {
        return *this;
    }

    [get() setBytes:bytes length:size atIndex:index];

    return *this;
}

ComputeCommandEncoder &ComputeCommandEncoder::setSamplerState(id<MTLSamplerState> state,
                                                              float lodMinClamp,
                                                              float lodMaxClamp,
                                                              uint32_t index)
{
    if (index >= kMaxShaderSamplers)
    {
        return *this;
    }

    [get() setSamplerState:state lodMinClamp:lodMinClamp lodMaxClamp:lodMaxClamp atIndex:index];

    return *this;
}
ComputeCommandEncoder &ComputeCommandEncoder::setTexture(const TextureRef &texture, uint32_t index)
{
    if (index >= kMaxShaderSamplers)
    {
        return *this;
    }

    cmdBuffer().setReadDependency(texture);
    [get() setTexture:(texture ? texture->get() : nil) atIndex:index];

    return *this;
}
ComputeCommandEncoder &ComputeCommandEncoder::setTextureForWrite(const TextureRef &texture,
                                                                 uint32_t index)
{
    if (index >= kMaxShaderSamplers)
    {
        return *this;
    }

    cmdBuffer().setWriteDependency(texture);
    return setTexture(texture, index);
}

ComputeCommandEncoder &ComputeCommandEncoder::dispatch(const MTLSize &threadGroupsPerGrid,
                                                       const MTLSize &threadsPerGroup)
{
    [get() dispatchThreadgroups:threadGroupsPerGrid threadsPerThreadgroup:threadsPerGroup];
    return *this;
}

ComputeCommandEncoder &ComputeCommandEncoder::dispatchNonUniform(const MTLSize &threadsPerGrid,
                                                                 const MTLSize &threadsPerGroup)
{
#if TARGET_OS_TV
    UNREACHABLE();
#else
    [get() dispatchThreads:threadsPerGrid threadsPerThreadgroup:threadsPerGroup];
#endif
    return *this;
}
}
}
