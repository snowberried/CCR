package com.snowberried.ctcinereviewer.render

import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLExt
import android.opengl.GLES30
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class VideoCorrectionShaderTest {
    @Test
    fun RGBShaderMatchesDesktopEquivalentCPUReferenceWithinTwoByteValues() {
        val source = byteArrayOf(
            8, 20, 40, -1, 64, 80, 96, -1, 120, 110, 100, -1,
            15, 45, 75, -1, 100, 140.toByte(), 180.toByte(), -1, 220.toByte(), 190.toByte(), 130.toByte(), -1,
            32, 96, 160.toByte(), -1, 180.toByte(), 120, 60, -1, 250.toByte(), 240.toByte(), 230.toByte(), -1,
        )
        val corrections = listOf(
            VideoCorrection.Default,
            VideoCorrection(level = 0.63f, width = 0.72f, gamma = 1.40f, sharpAmount = 0.65f, invert = true),
        )

        corrections.forEach { correction ->
            val expected = applyVideoCorrectionReference(source, 3, 3, correction)
            val actual = renderWithCorrectionShader(source, 3, 3, correction)
            expected.indices.forEach { index ->
                val expectedByte = expected[index].toInt() and 0xff
                val actualByte = actual[index].toInt() and 0xff
                assertTrue(
                    "shader mismatch at byte $index: expected=$expectedByte actual=$actualByte",
                    abs(expectedByte - actualByte) <= MAX_BYTE_ERROR,
                )
            }
        }
    }

    private fun renderWithCorrectionShader(
        source: ByteArray,
        width: Int,
        height: Int,
        correction: VideoCorrection,
    ): ByteArray {
        val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(display != EGL14.EGL_NO_DISPLAY)
        check(EGL14.eglInitialize(display, IntArray(2), 0, IntArray(2), 0))
        val configs = arrayOfNulls<EGLConfig>(1)
        val configCount = IntArray(1)
        check(
            EGL14.eglChooseConfig(
                display,
                intArrayOf(
                    EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
                    EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                    EGL14.EGL_RED_SIZE, 8,
                    EGL14.EGL_GREEN_SIZE, 8,
                    EGL14.EGL_BLUE_SIZE, 8,
                    EGL14.EGL_ALPHA_SIZE, 8,
                    EGL14.EGL_NONE,
                ),
                0,
                configs,
                0,
                1,
                configCount,
                0,
            ) && configCount[0] == 1,
        )
        val config = requireNotNull(configs[0])
        val context = EGL14.eglCreateContext(
            display,
            config,
            EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE),
            0,
        )
        check(context != EGL14.EGL_NO_CONTEXT)
        val surface = EGL14.eglCreatePbufferSurface(
            display,
            config,
            intArrayOf(EGL14.EGL_WIDTH, width, EGL14.EGL_HEIGHT, height, EGL14.EGL_NONE),
            0,
        )
        check(surface != EGL14.EGL_NO_SURFACE)
        check(EGL14.eglMakeCurrent(display, surface, surface, context))

        var program = 0
        var texture = 0
        var outputTexture = 0
        var framebuffer = 0
        var vertexArray = 0
        var vertexBuffer = 0
        try {
            program = createProgram(VERTEX_SHADER, EglFrameRenderer.TEXTURE_FRAGMENT_SHADER)
            texture = IntArray(1).also { GLES30.glGenTextures(1, it, 0) }[0]
            outputTexture = IntArray(1).also { GLES30.glGenTextures(1, it, 0) }[0]
            framebuffer = IntArray(1).also { GLES30.glGenFramebuffers(1, it, 0) }[0]
            vertexArray = IntArray(1).also { GLES30.glGenVertexArrays(1, it, 0) }[0]
            vertexBuffer = IntArray(1).also { GLES30.glGenBuffers(1, it, 0) }[0]
            GLES30.glBindVertexArray(vertexArray)
            GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, vertexBuffer)
            val vertices = ByteBuffer.allocateDirect(VERTICES.size * Float.SIZE_BYTES)
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer()
                .apply {
                    put(VERTICES)
                    position(0)
                }
            GLES30.glBufferData(
                GLES30.GL_ARRAY_BUFFER,
                VERTICES.size * Float.SIZE_BYTES,
                vertices,
                GLES30.GL_STATIC_DRAW,
            )
            GLES30.glEnableVertexAttribArray(0)
            GLES30.glVertexAttribPointer(0, 2, GLES30.GL_FLOAT, false, 4 * Float.SIZE_BYTES, 0)
            GLES30.glEnableVertexAttribArray(1)
            GLES30.glVertexAttribPointer(1, 2, GLES30.GL_FLOAT, false, 4 * Float.SIZE_BYTES, 2 * Float.SIZE_BYTES)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, texture)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
            val input = ByteBuffer.allocateDirect(source.size).order(ByteOrder.nativeOrder()).apply {
                put(source)
                position(0)
            }
            GLES30.glTexImage2D(
                GLES30.GL_TEXTURE_2D,
                0,
                GLES30.GL_RGBA8,
                width,
                height,
                0,
                GLES30.GL_RGBA,
                GLES30.GL_UNSIGNED_BYTE,
                input,
            )
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, outputTexture)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST)
            GLES30.glTexImage2D(
                GLES30.GL_TEXTURE_2D,
                0,
                GLES30.GL_RGBA8,
                width,
                height,
                0,
                GLES30.GL_RGBA,
                GLES30.GL_UNSIGNED_BYTE,
                null,
            )
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, framebuffer)
            GLES30.glFramebufferTexture2D(
                GLES30.GL_FRAMEBUFFER,
                GLES30.GL_COLOR_ATTACHMENT0,
                GLES30.GL_TEXTURE_2D,
                outputTexture,
                0,
            )
            check(GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER) == GLES30.GL_FRAMEBUFFER_COMPLETE)
            GLES30.glDrawBuffers(1, intArrayOf(GLES30.GL_COLOR_ATTACHMENT0), 0)
            GLES30.glReadBuffer(GLES30.GL_COLOR_ATTACHMENT0)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, texture)
            GLES30.glUseProgram(program)
            GLES30.glUniform1i(GLES30.glGetUniformLocation(program, "uTexture"), 0)
            GLES30.glUniform1f(GLES30.glGetUniformLocation(program, "displayLevel"), correction.level)
            GLES30.glUniform1f(GLES30.glGetUniformLocation(program, "displayWidth"), correction.width)
            GLES30.glUniform1f(GLES30.glGetUniformLocation(program, "displayGamma"), correction.gamma)
            GLES30.glUniform1f(
                GLES30.glGetUniformLocation(program, "displayInvert"),
                if (correction.invert) 1f else 0f,
            )
            GLES30.glUniform1f(GLES30.glGetUniformLocation(program, "displaySharp"), correction.sharpAmount)
            GLES30.glUniform1f(
                GLES30.glGetUniformLocation(program, "displayBypass"),
                if (correction.isDefault) 1f else 0f,
            )
            GLES30.glUniform2f(GLES30.glGetUniformLocation(program, "texelSize"), 1f / width, 1f / height)
            GLES30.glDisable(GLES30.GL_BLEND)
            GLES30.glDisable(GLES30.GL_CULL_FACE)
            GLES30.glDisable(GLES30.GL_DEPTH_TEST)
            GLES30.glDisable(GLES30.GL_SCISSOR_TEST)
            GLES30.glColorMask(true, true, true, true)
            GLES30.glViewport(0, 0, width, height)
            GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
            check(GLES30.glGetError() == GLES30.GL_NO_ERROR)
            GLES30.glFinish()

            val output = ByteBuffer.allocateDirect(source.size).order(ByteOrder.nativeOrder())
            GLES30.glReadPixels(0, 0, width, height, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, output)
            output.position(0)
            return ByteArray(source.size).also(output::get)
        } finally {
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
            if (program != 0) GLES30.glDeleteProgram(program)
            if (texture != 0) GLES30.glDeleteTextures(1, intArrayOf(texture), 0)
            if (outputTexture != 0) GLES30.glDeleteTextures(1, intArrayOf(outputTexture), 0)
            if (framebuffer != 0) GLES30.glDeleteFramebuffers(1, intArrayOf(framebuffer), 0)
            if (vertexBuffer != 0) GLES30.glDeleteBuffers(1, intArrayOf(vertexBuffer), 0)
            if (vertexArray != 0) GLES30.glDeleteVertexArrays(1, intArrayOf(vertexArray), 0)
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            EGL14.eglDestroySurface(display, surface)
            EGL14.eglDestroyContext(display, context)
            EGL14.eglTerminate(display)
        }
    }

    private fun createProgram(vertexSource: String, fragmentSource: String): Int {
        fun compile(type: Int, source: String): Int {
            val shader = GLES30.glCreateShader(type)
            GLES30.glShaderSource(shader, source)
            GLES30.glCompileShader(shader)
            val status = IntArray(1)
            GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
            check(status[0] == GLES30.GL_TRUE) { GLES30.glGetShaderInfoLog(shader) }
            return shader
        }
        val vertex = compile(GLES30.GL_VERTEX_SHADER, vertexSource)
        val fragment = compile(GLES30.GL_FRAGMENT_SHADER, fragmentSource)
        return GLES30.glCreateProgram().also { program ->
            GLES30.glAttachShader(program, vertex)
            GLES30.glAttachShader(program, fragment)
            GLES30.glLinkProgram(program)
            val status = IntArray(1)
            GLES30.glGetProgramiv(program, GLES30.GL_LINK_STATUS, status, 0)
            GLES30.glDeleteShader(vertex)
            GLES30.glDeleteShader(fragment)
            check(status[0] == GLES30.GL_TRUE) { GLES30.glGetProgramInfoLog(program) }
        }
    }

    private companion object {
        const val MAX_BYTE_ERROR = 2
        const val VERTEX_SHADER = """#version 300 es
            layout(location = 0) in vec2 aPosition;
            layout(location = 1) in vec2 aTextureCoordinate;
            out vec2 vTextureCoordinate;
            void main() {
              gl_Position = vec4(aPosition, 0.0, 1.0);
              vTextureCoordinate = aTextureCoordinate;
            }
        """
        val VERTICES = floatArrayOf(
            -1f, -1f, 0f, 0f,
            1f, -1f, 1f, 0f,
            -1f, 1f, 0f, 1f,
            1f, 1f, 1f, 1f,
        )
    }
}
