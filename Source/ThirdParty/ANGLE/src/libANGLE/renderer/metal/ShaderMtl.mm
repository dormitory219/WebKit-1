//
// Copyright 2019 The ANGLE Project Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// ShaderMtl.mm:
//    Implements the class methods for ShaderMtl.
//

#include "libANGLE/renderer/metal/ShaderMtl.h"

#include "common/debug.h"
#include "compiler/translator/TranslatorMetal.h"
#include "compiler/translator/TranslatorMetalDirect.h"
#include "libANGLE/Context.h"
#include "libANGLE/Shader.h"
#include "libANGLE/WorkerThread.h"
#include "libANGLE/renderer/metal/ContextMtl.h"
#include "libANGLE/renderer/metal/DisplayMtl.h"

namespace rx
{

ShaderMtl::ShaderMtl(const gl::ShaderState &state) : ShaderImpl(state) {}

ShaderMtl::~ShaderMtl() {}

class TranslateTask : public angle::Closure
{
  public:
    TranslateTask(ShHandle handle, ShCompileOptions options, const std::string &source)
        : mHandle(handle), mOptions(options), mSource(source), mResult(false)
    {}

    void operator()() override
    {
        const char *source = mSource.c_str();
        mResult            = sh::Compile(mHandle, &source, 1, mOptions);
    }

    bool getResult() { return mResult; }

    ShHandle getHandle() { return mHandle; }

  private:
    ShHandle mHandle;
    ShCompileOptions mOptions;
    std::string mSource;
    bool mResult;
};

class MTLWaitableCompileEventImpl final : public WaitableCompileEvent
{
  public:
    MTLWaitableCompileEventImpl(ShaderMtl *shader,
                                std::shared_ptr<angle::WaitableEvent> waitableEvent,
                                std::shared_ptr<TranslateTask> translateTask)
        : WaitableCompileEvent(waitableEvent), mTranslateTask(translateTask), mShader(shader)
    {}

    bool getResult() override { return mTranslateTask->getResult(); }

    bool postTranslate(std::string *infoLog) override
    {
        sh::TShHandleBase *base    = static_cast<sh::TShHandleBase *>(mTranslateTask->getHandle());
        auto translatorMetalDirect = base->getAsTranslatorMetalDirect();
        if (translatorMetalDirect != nullptr)
        {
            // Copy reflection from translation.
            mShader->translatorMetalReflection =
                *(translatorMetalDirect->getTranslatorMetalReflection());
            translatorMetalDirect->getTranslatorMetalReflection()->reset();
        }
        return true;
    }

  private:
    std::shared_ptr<TranslateTask> mTranslateTask;
    ShaderMtl *mShader;
};

std::shared_ptr<WaitableCompileEvent> ShaderMtl::compileImplMtl(
    const gl::Context *context,
    gl::ShCompilerInstance *compilerInstance,
    const std::string &source,
    ShCompileOptions compileOptions)
{
#if defined(ANGLE_ENABLE_ASSERTS)
    compileOptions |= SH_VALIDATE_AST;
#endif

    auto workerThreadPool = context->getWorkerThreadPool();
    auto translateTask =
        std::make_shared<TranslateTask>(compilerInstance->getHandle(), compileOptions, source);

    return std::make_shared<MTLWaitableCompileEventImpl>(
        this, angle::WorkerThreadPool::PostWorkerTask(workerThreadPool, translateTask),
        translateTask);
}

std::shared_ptr<WaitableCompileEvent> ShaderMtl::compile(const gl::Context *context,
                                                         gl::ShCompilerInstance *compilerInstance,
                                                         ShCompileOptions options)
{
    ContextMtl *contextMtl = mtl::GetImpl(context);
    if (getState().getShaderType() == gl::ShaderType::Vertex &&
        !contextMtl->getDisplay()->getFeatures().hasBaseVertexInstancedDraw.enabled)
    {
        // Emulate gl_InstanceID
        sh::TShHandleBase *base = static_cast<sh::TShHandleBase *>(compilerInstance->getHandle());
        auto translatorMetalDirect = base->getAsTranslatorMetalDirect();
        if (translatorMetalDirect == nullptr)
        {
            auto translatorMetal = static_cast<sh::TranslatorMetal *>(base->getAsCompiler());
            translatorMetal->enableEmulatedInstanceID(true);
        }
        else
        {
            translatorMetalDirect->enableEmulatedInstanceID(true);
        }
    }
    ShCompileOptions compileOptions = SH_INITIALIZE_UNINITIALIZED_LOCALS;

    bool isWebGL = context->getExtensions().webglCompatibility;
    if (isWebGL && mState.getShaderType() != gl::ShaderType::Compute)
    {
        compileOptions |= SH_INIT_OUTPUT_VARIABLES;
    }

    compileOptions |= SH_CLAMP_POINT_SIZE;
#if defined(ANGLE_PLATFORM_IOS) && !defined(ANGLE_PLATFORM_MACCATALYST)
    compileOptions |= SH_CLAMP_FRAG_DEPTH;
#endif

    return compileImplMtl(context, compilerInstance, getState().getSource(), compileOptions | options);
}

std::string ShaderMtl::getDebugInfo() const
{
    return mState.getTranslatedSource();
}

}  // namespace rx
