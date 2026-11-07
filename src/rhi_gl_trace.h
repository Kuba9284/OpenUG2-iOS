/* rhi_gl_trace.h -- Super Debug Mode (iOS): names the GL call that raises an error.
 *
 * Included by rhi_gl.c only, after the state-tracker header and after glt_after() is declared. Every GL entry point
 * the backend uses is redefined as "call it, then glt_after(name, line)", which (when Super Debug Mode is on) runs
 * glGetError and logs the first occurrence of each (call, line) with its frame number. Off, the cost is one branch.
 * A macro that expands to its own name is not expanded again, so the inner call is the real function -- or the
 * tracker's glsXxx where rhi_gl_state.h maps it (those are #undef'd and re-pointed here).
 * Generated from the entry points rhi_gl.c uses; add a line when it starts using another. */
#ifndef OPENUG2_GL_TRACE_H
#define OPENUG2_GL_TRACE_H
#ifdef OPENUG2_IOS

#define GLT_V(name, call) ((void)(call), glt_after(name, __LINE__))
#define GLT_R(name, call) ({ __typeof__(call) glt_r_ = (call); glt_after(name, __LINE__); glt_r_; })

#undef glBindBuffer
#define glBindBuffer(...) GLT_V("glBindBuffer", glsBindBuffer(__VA_ARGS__))
#undef glBindFramebuffer
#define glBindFramebuffer(...) GLT_V("glBindFramebuffer", glsBindFramebuffer(__VA_ARGS__))
#define glDeleteShader(...) GLT_V("glDeleteShader", glDeleteShader(__VA_ARGS__))
#undef glActiveTexture
#define glActiveTexture(...) GLT_V("glActiveTexture", glsActiveTexture(__VA_ARGS__))
#undef glViewport
#define glViewport(...) GLT_V("glViewport", glsViewport(__VA_ARGS__))
#undef glVertexAttribPointer
#define glVertexAttribPointer(...) GLT_V("glVertexAttribPointer", glsVertexAttribPointer(__VA_ARGS__))
#define glTexParameteri(...) GLT_V("glTexParameteri", glTexParameteri(__VA_ARGS__))
#undef glDepthMask
#define glDepthMask(...) GLT_V("glDepthMask", glsDepthMask(__VA_ARGS__))
#undef glDeleteProgram
#define glDeleteProgram(...) GLT_V("glDeleteProgram", glsDeleteProgram(__VA_ARGS__))
#undef glColorMask
#define glColorMask(...) GLT_V("glColorMask", glsColorMask(__VA_ARGS__))
#define glBufferData(...) GLT_V("glBufferData", glBufferData(__VA_ARGS__))
#undef glDisableVertexAttribArray
#define glDisableVertexAttribArray(...) GLT_V("glDisableVertexAttribArray", glsDisableVertexAttribArray(__VA_ARGS__))
#define glCopyTexImage2D(...) GLT_V("glCopyTexImage2D", glCopyTexImage2D(__VA_ARGS__))
#undef glBindTexture
#define glBindTexture(...) GLT_V("glBindTexture", glsBindTexture(__VA_ARGS__))
#undef glUseProgram
#define glUseProgram(...) GLT_V("glUseProgram", glsUseProgram(__VA_ARGS__))
#define glStencilMaskSeparate(...) GLT_V("glStencilMaskSeparate", glStencilMaskSeparate(__VA_ARGS__))
#define glStencilMask(...) GLT_V("glStencilMask", glStencilMask(__VA_ARGS__))
#define glRenderbufferStorage(...) GLT_V("glRenderbufferStorage", glRenderbufferStorage(__VA_ARGS__))
#undef glLineWidth
#define glLineWidth(...) GLT_V("glLineWidth", glsLineWidth(__VA_ARGS__))
#define glGenTextures(...) GLT_V("glGenTextures", glGenTextures(__VA_ARGS__))
#define glGenRenderbuffers(...) GLT_V("glGenRenderbuffers", glGenRenderbuffers(__VA_ARGS__))
#define glGenFramebuffers(...) GLT_V("glGenFramebuffers", glGenFramebuffers(__VA_ARGS__))
#define glGenBuffers(...) GLT_V("glGenBuffers", glGenBuffers(__VA_ARGS__))
#define glFramebufferTexture2D(...) GLT_V("glFramebufferTexture2D", glFramebufferTexture2D(__VA_ARGS__))
#define glFramebufferRenderbuffer(...) GLT_V("glFramebufferRenderbuffer", glFramebufferRenderbuffer(__VA_ARGS__))
#undef glEnableVertexAttribArray
#define glEnableVertexAttribArray(...) GLT_V("glEnableVertexAttribArray", glsEnableVertexAttribArray(__VA_ARGS__))
#undef glDepthFunc
#define glDepthFunc(...) GLT_V("glDepthFunc", glsDepthFunc(__VA_ARGS__))
#undef glClearDepthf
#define glClearDepthf(...) GLT_V("glClearDepthf", glsClearDepthf(__VA_ARGS__))
#undef glClearColor
#define glClearColor(...) GLT_V("glClearColor", glsClearColor(__VA_ARGS__))
#undef glBlendFuncSeparate
#define glBlendFuncSeparate(...) GLT_V("glBlendFuncSeparate", glsBlendFuncSeparate(__VA_ARGS__))
#undef glBlendEquationSeparate
#define glBlendEquationSeparate(...) GLT_V("glBlendEquationSeparate", glsBlendEquationSeparate(__VA_ARGS__))
#undef glBindRenderbuffer
#define glBindRenderbuffer(...) GLT_V("glBindRenderbuffer", glsBindRenderbuffer(__VA_ARGS__))
#define glAttachShader(...) GLT_V("glAttachShader", glAttachShader(__VA_ARGS__))
#undef glUniformMatrix4fv
#define glUniformMatrix4fv(...) GLT_V("glUniformMatrix4fv", glsUniformMatrix4fv(__VA_ARGS__))
#undef glUniform4fv
#define glUniform4fv(...) GLT_V("glUniform4fv", glsUniform4fv(__VA_ARGS__))
#undef glUniform3fv
#define glUniform3fv(...) GLT_V("glUniform3fv", glsUniform3fv(__VA_ARGS__))
#undef glUniform2fv
#define glUniform2fv(...) GLT_V("glUniform2fv", glsUniform2fv(__VA_ARGS__))
#undef glUniform1i
#define glUniform1i(...) GLT_V("glUniform1i", glsUniform1i(__VA_ARGS__))
#undef glUniform1fv
#define glUniform1fv(...) GLT_V("glUniform1fv", glsUniform1fv(__VA_ARGS__))
#define glTexParameterf(...) GLT_V("glTexParameterf", glTexParameterf(__VA_ARGS__))
#define glTexImage2D(...) GLT_V("glTexImage2D", glTexImage2D(__VA_ARGS__))
#define glStencilOp(...) GLT_V("glStencilOp", glStencilOp(__VA_ARGS__))
#define glStencilFunc(...) GLT_V("glStencilFunc", glStencilFunc(__VA_ARGS__))
#define glShaderSource(...) GLT_V("glShaderSource", glShaderSource(__VA_ARGS__))
#define glReadPixels(...) GLT_V("glReadPixels", glReadPixels(__VA_ARGS__))
#define glPixelStorei(...) GLT_V("glPixelStorei", glPixelStorei(__VA_ARGS__))
#undef glLinkProgram
#define glLinkProgram(...) GLT_V("glLinkProgram", glsLinkProgram(__VA_ARGS__))
#define glGenerateMipmap(...) GLT_V("glGenerateMipmap", glGenerateMipmap(__VA_ARGS__))
#undef glDeleteTextures
#define glDeleteTextures(...) GLT_V("glDeleteTextures", glsDeleteTextures(__VA_ARGS__))
#undef glDeleteRenderbuffers
#define glDeleteRenderbuffers(...) GLT_V("glDeleteRenderbuffers", glsDeleteRenderbuffers(__VA_ARGS__))
#undef glDeleteFramebuffers
#define glDeleteFramebuffers(...) GLT_V("glDeleteFramebuffers", glsDeleteFramebuffers(__VA_ARGS__))
#undef glDeleteBuffers
#define glDeleteBuffers(...) GLT_V("glDeleteBuffers", glsDeleteBuffers(__VA_ARGS__))
#define glCullFace(...) GLT_V("glCullFace", glCullFace(__VA_ARGS__))
#define glCopyTexSubImage2D(...) GLT_V("glCopyTexSubImage2D", glCopyTexSubImage2D(__VA_ARGS__))
#define glCompressedTexImage2D(...) GLT_V("glCompressedTexImage2D", glCompressedTexImage2D(__VA_ARGS__))
#define glCompileShader(...) GLT_V("glCompileShader", glCompileShader(__VA_ARGS__))
#define glClearStencil(...) GLT_V("glClearStencil", glClearStencil(__VA_ARGS__))
#define glClear(...) GLT_V("glClear", glClear(__VA_ARGS__))
#define glBufferSubData(...) GLT_V("glBufferSubData", glBufferSubData(__VA_ARGS__))
#define glBindAttribLocation(...) GLT_V("glBindAttribLocation", glBindAttribLocation(__VA_ARGS__))
#undef glEnable
#define glEnable(...) GLT_V("glEnable", glsEnable(__VA_ARGS__))
#undef glDisable
#define glDisable(...) GLT_V("glDisable", glsDisable(__VA_ARGS__))
#define glDrawElements(...) GLT_V("glDrawElements", glDrawElements(__VA_ARGS__))
#define glDrawArrays(...) GLT_V("glDrawArrays", glDrawArrays(__VA_ARGS__))
#define glGetShaderiv(...) GLT_V("glGetShaderiv", glGetShaderiv(__VA_ARGS__))
#define glGetProgramiv(...) GLT_V("glGetProgramiv", glGetProgramiv(__VA_ARGS__))
#define glGetShaderInfoLog(...) GLT_V("glGetShaderInfoLog", glGetShaderInfoLog(__VA_ARGS__))
#define glGetProgramInfoLog(...) GLT_V("glGetProgramInfoLog", glGetProgramInfoLog(__VA_ARGS__))
#define glGetIntegerv(...) GLT_V("glGetIntegerv", glGetIntegerv(__VA_ARGS__))
#define glGetFloatv(...) GLT_V("glGetFloatv", glGetFloatv(__VA_ARGS__))
#define glCreateShader(...) GLT_R("glCreateShader", glCreateShader(__VA_ARGS__))
#define glCreateProgram(...) GLT_R("glCreateProgram", glCreateProgram(__VA_ARGS__))
#define glGetUniformLocation(...) GLT_R("glGetUniformLocation", glGetUniformLocation(__VA_ARGS__))
#define glCheckFramebufferStatus(...) GLT_R("glCheckFramebufferStatus", glCheckFramebufferStatus(__VA_ARGS__))

/* glGetError() consumers see the error the tracer already read (see glt_stash in rhi_gl.c). */
#define glGetError() glt_get_error()

#endif /* OPENUG2_IOS */
#endif
