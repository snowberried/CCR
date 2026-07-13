import { originalVideoDisplay, videoDisplayEqual, type VideoDisplayState } from "../domain/videoDisplay";

type PlaneLayout = {
  offset: number;
  stride: number;
};

type FrameLayout = {
  y: PlaneLayout;
  u: PlaneLayout;
  v: PlaneLayout;
  byteLength: number;
};

type FrameColorSpace = {
  fullRange: boolean;
  matrix: string;
  webglAllowed: boolean;
};

const VERTEX_SHADER = `#version 300 es
in vec2 position;
in vec2 texCoord;
out vec2 uv;
void main() {
  gl_Position = vec4(position, 0.0, 1.0);
  uv = texCoord;
}`;

const FRAGMENT_SHADER = `#version 300 es
precision highp float;
in vec2 uv;
out vec4 color;
uniform sampler2D yTex;
uniform sampler2D uTex;
uniform sampler2D vTex;
uniform float displayLevel;
uniform float displayWidth;
uniform float displayGamma;
uniform float displayInvert;
uniform float displaySharp;
uniform float displayBypass;
uniform vec2 texelSize;
vec3 sourceRgb(vec2 point) {
  float y = (texture(yTex, point).r * 255.0 - 16.0) * 1.16438356;
  float u = texture(uTex, point).r * 255.0 - 128.0;
  float v = texture(vTex, point).r * 255.0 - 128.0;
  vec3 rgb = vec3(
    y + 1.59602678 * v,
    y - 0.39176229 * u - 0.81296765 * v,
    y + 2.01723214 * u
  ) - vec3(1.0);
  return clamp(rgb / 255.0, 0.0, 1.0);
}
float mappedLuma(vec2 point) {
  vec3 rgb = sourceRgb(point);
  float luminance = dot(rgb, vec3(0.299, 0.587, 0.114));
  float mapped = clamp((luminance - (displayLevel - displayWidth * 0.5)) / displayWidth, 0.0, 1.0);
  mapped = pow(mapped, 1.0 / displayGamma);
  return mix(mapped, 1.0 - mapped, displayInvert);
}
void main() {
  vec3 rgb = sourceRgb(uv);
  if (displayBypass > 0.5) {
    color = vec4(rgb, 1.0);
    return;
  }
  float originalLuma = dot(rgb, vec3(0.299, 0.587, 0.114));
  float adjustedLuma = mappedLuma(uv);
  if (displaySharp > 0.0) {
    float neighbors = mappedLuma(uv - vec2(texelSize.x, 0.0))
      + mappedLuma(uv + vec2(texelSize.x, 0.0))
      + mappedLuma(uv - vec2(0.0, texelSize.y))
      + mappedLuma(uv + vec2(0.0, texelSize.y));
    adjustedLuma = clamp(adjustedLuma + displaySharp * 0.25 * (4.0 * adjustedLuma - neighbors), 0.0, 1.0);
  }
  color = vec4(clamp(rgb + vec3(adjustedLuma - originalLuma), 0.0, 1.0), 1.0);
}`;

function compileShader(gl: WebGL2RenderingContext, type: number, source: string): WebGLShader {
  const shader = gl.createShader(type);
  if (!shader) throw new Error("I420_WEBGL_SHADER_CREATE_FAILED");
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    gl.deleteShader(shader);
    throw new Error("I420_WEBGL_SHADER_COMPILE_FAILED");
  }
  return shader;
}

export class I420WebglRenderer {
  readonly canvas = document.createElement("canvas");
  private readonly gl: WebGL2RenderingContext;
  private readonly program: WebGLProgram;
  private readonly textures: WebGLTexture[];
  private readonly buffers: WebGLBuffer[];
  private readonly displayUniforms: Record<string, WebGLUniformLocation | null>;
  private lost = false;
  private width = 0;
  private height = 0;
  private textureUploadCount = 0;

  constructor() {
    const gl = this.canvas.getContext("webgl2", { alpha: false, premultipliedAlpha: false });
    if (!gl) throw new Error("I420_WEBGL2_UNAVAILABLE");
    this.gl = gl;
    this.canvas.addEventListener("webglcontextlost", this.onContextLost);

    const vertex = compileShader(gl, gl.VERTEX_SHADER, VERTEX_SHADER);
    const fragment = compileShader(gl, gl.FRAGMENT_SHADER, FRAGMENT_SHADER);
    const program = gl.createProgram();
    if (!program) throw new Error("I420_WEBGL_PROGRAM_CREATE_FAILED");
    gl.attachShader(program, vertex);
    gl.attachShader(program, fragment);
    gl.linkProgram(program);
    gl.deleteShader(vertex);
    gl.deleteShader(fragment);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      gl.deleteProgram(program);
      throw new Error("I420_WEBGL_PROGRAM_LINK_FAILED");
    }
    this.program = program;
    gl.useProgram(program);

    const positions = new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]);
    const coordinates = new Float32Array([0, 1, 1, 1, 0, 0, 1, 0]);
    this.buffers = [
      this.createAttribute("position", positions),
      this.createAttribute("texCoord", coordinates),
    ];
    this.textures = [0, 1, 2].map((unit) => this.createTexture(unit));
    ["yTex", "uTex", "vTex"].forEach((name, unit) => {
      gl.uniform1i(gl.getUniformLocation(program, name), unit);
    });
    this.displayUniforms = Object.fromEntries([
      "displayLevel", "displayWidth", "displayGamma", "displayInvert", "displaySharp", "displayBypass", "texelSize",
    ].map((name) => [name, gl.getUniformLocation(program, name)]));
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
  }

  render(input: {
    pixels: Uint8Array;
    width: number;
    height: number;
    layout: FrameLayout;
    colorSpace: FrameColorSpace;
    display: VideoDisplayState;
  }): HTMLCanvasElement {
    if (this.lost || this.gl.isContextLost()) throw new Error("I420_WEBGL_CONTEXT_LOST");
    if (!input.colorSpace.webglAllowed || input.colorSpace.fullRange || input.colorSpace.matrix !== "smpte170m") {
      throw new Error("I420_WEBGL_COLORSPACE_UNSUPPORTED");
    }

    const chromaWidth = Math.ceil(input.width / 2);
    const chromaHeight = Math.ceil(input.height / 2);
    if (
      input.layout.y.stride < input.width ||
      input.layout.u.stride < chromaWidth ||
      input.layout.v.stride < chromaWidth ||
      input.pixels.byteLength < input.layout.byteLength
    ) {
      throw new Error("I420_WEBGL_LAYOUT_INVALID");
    }

    if (this.width !== input.width || this.height !== input.height) {
      this.width = input.width;
      this.height = input.height;
      this.canvas.width = input.width;
      this.canvas.height = input.height;
      this.allocatePlane(0, input.width, input.height);
      this.allocatePlane(1, chromaWidth, chromaHeight);
      this.allocatePlane(2, chromaWidth, chromaHeight);
    }

    this.uploadPlane(0, input.width, input.height, input.layout.y, input.layout.u.offset, input.pixels);
    this.uploadPlane(1, chromaWidth, chromaHeight, input.layout.u, input.layout.v.offset, input.pixels);
    this.uploadPlane(2, chromaWidth, chromaHeight, input.layout.v, input.layout.byteLength, input.pixels);
    this.gl.pixelStorei(this.gl.UNPACK_ROW_LENGTH, 0);
    this.textureUploadCount += 3;
    this.draw(input.display);
    return this.canvas;
  }

  redraw(display: VideoDisplayState): HTMLCanvasElement {
    if (this.lost || this.gl.isContextLost()) throw new Error("I420_WEBGL_CONTEXT_LOST");
    if (this.width <= 0 || this.height <= 0) throw new Error("I420_WEBGL_FRAME_MISSING");
    this.draw(display);
    return this.canvas;
  }

  getStats(): { textureUploadCount: number } {
    return { textureUploadCount: this.textureUploadCount };
  }

  dispose(): void {
    this.canvas.removeEventListener("webglcontextlost", this.onContextLost);
    for (const texture of this.textures) this.gl.deleteTexture(texture);
    for (const buffer of this.buffers) this.gl.deleteBuffer(buffer);
    this.gl.deleteProgram(this.program);
  }

  loseContext(): void {
    this.gl.getExtension("WEBGL_lose_context")?.loseContext();
  }

  private readonly onContextLost = (event: Event) => {
    event.preventDefault();
    this.lost = true;
  };

  private draw(display: VideoDisplayState): void {
    const gl = this.gl;
    gl.useProgram(this.program);
    gl.uniform1f(this.displayUniforms.displayLevel, display.level);
    gl.uniform1f(this.displayUniforms.displayWidth, display.width);
    gl.uniform1f(this.displayUniforms.displayGamma, display.gamma);
    gl.uniform1f(this.displayUniforms.displayInvert, display.invert ? 1 : 0);
    gl.uniform1f(this.displayUniforms.displaySharp, display.sharpAmount);
    gl.uniform1f(this.displayUniforms.displayBypass, videoDisplayEqual(display, originalVideoDisplay()) ? 1 : 0);
    gl.uniform2f(this.displayUniforms.texelSize, 1 / this.width, 1 / this.height);
    gl.viewport(0, 0, this.width, this.height);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  private createAttribute(name: string, values: Float32Array): WebGLBuffer {
    const buffer = this.gl.createBuffer();
    if (!buffer) throw new Error("I420_WEBGL_BUFFER_CREATE_FAILED");
    this.gl.bindBuffer(this.gl.ARRAY_BUFFER, buffer);
    this.gl.bufferData(this.gl.ARRAY_BUFFER, values, this.gl.STATIC_DRAW);
    const location = this.gl.getAttribLocation(this.program, name);
    this.gl.enableVertexAttribArray(location);
    this.gl.vertexAttribPointer(location, 2, this.gl.FLOAT, false, 0, 0);
    return buffer;
  }

  private createTexture(unit: number): WebGLTexture {
    const texture = this.gl.createTexture();
    if (!texture) throw new Error("I420_WEBGL_TEXTURE_CREATE_FAILED");
    this.gl.activeTexture(this.gl.TEXTURE0 + unit);
    this.gl.bindTexture(this.gl.TEXTURE_2D, texture);
    this.gl.texParameteri(this.gl.TEXTURE_2D, this.gl.TEXTURE_MIN_FILTER, this.gl.NEAREST);
    this.gl.texParameteri(this.gl.TEXTURE_2D, this.gl.TEXTURE_MAG_FILTER, this.gl.NEAREST);
    this.gl.texParameteri(this.gl.TEXTURE_2D, this.gl.TEXTURE_WRAP_S, this.gl.CLAMP_TO_EDGE);
    this.gl.texParameteri(this.gl.TEXTURE_2D, this.gl.TEXTURE_WRAP_T, this.gl.CLAMP_TO_EDGE);
    return texture;
  }

  private allocatePlane(unit: number, width: number, height: number): void {
    this.gl.activeTexture(this.gl.TEXTURE0 + unit);
    this.gl.bindTexture(this.gl.TEXTURE_2D, this.textures[unit]);
    this.gl.texImage2D(
      this.gl.TEXTURE_2D,
      0,
      this.gl.R8,
      width,
      height,
      0,
      this.gl.RED,
      this.gl.UNSIGNED_BYTE,
      null,
    );
  }

  private uploadPlane(
    unit: number,
    width: number,
    height: number,
    layout: PlaneLayout,
    endOffset: number,
    pixels: Uint8Array,
  ): void {
    const requiredBytes = layout.stride * height;
    if (endOffset - layout.offset < requiredBytes) throw new Error("I420_WEBGL_PLANE_INVALID");
    this.gl.activeTexture(this.gl.TEXTURE0 + unit);
    this.gl.bindTexture(this.gl.TEXTURE_2D, this.textures[unit]);
    this.gl.pixelStorei(this.gl.UNPACK_ROW_LENGTH, layout.stride);
    this.gl.texSubImage2D(
      this.gl.TEXTURE_2D,
      0,
      0,
      0,
      width,
      height,
      this.gl.RED,
      this.gl.UNSIGNED_BYTE,
      pixels.subarray(layout.offset, layout.offset + requiredBytes),
    );
  }
}
