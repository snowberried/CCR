const { app, BrowserWindow } = require("electron");
const { spawnSync } = require("node:child_process");
const { readdirSync, mkdirSync, writeFileSync } = require("node:fs");
const path = require("node:path");

const root = path.resolve("local-samples");
const ffmpeg = path.resolve("tools/ffmpeg/bin/ffmpeg.exe");
const ffprobe = path.resolve("tools/ffmpeg/bin/ffprobe.exe");
const outputPath = path.resolve("temp/phase22-video-frame-color.json");
const extensions = new Set([".mp4", ".mov", ".avi", ".mkv"]);
const profiles = [
  { name: "bt601-limited", fullRange: false, matrix: "smpte170m", primaries: "smpte170m", transfer: "smpte170m" },
  { name: "bt709-limited", fullRange: false, matrix: "bt709", primaries: "bt709", transfer: "bt709" },
  { name: "bt601-full", fullRange: true, matrix: "smpte170m", primaries: "smpte170m", transfer: "smpte170m" },
  { name: "bt709-full", fullRange: true, matrix: "bt709", primaries: "bt709", transfer: "bt709" },
];
const webglProfiles = [
  { name: "webgl-nearest-minus-one", filter: "nearest", offsetX: 0, offsetY: 0, bias: -1 },
  { name: "webgl-nearest-minus-half", filter: "nearest", offsetX: 0, offsetY: 0, bias: -0.5 },
  { name: "webgl-nearest", filter: "nearest", offsetX: 0, offsetY: 0, bias: 0 },
  { name: "webgl-nearest-plus-half", filter: "nearest", offsetX: 0, offsetY: 0, bias: 0.5 },
  { name: "webgl-nearest-plus-one", filter: "nearest", offsetX: 0, offsetY: 0, bias: 1 },
];

function mediaFiles(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return mediaFiles(fullPath);
    return entry.isFile() && extensions.has(path.extname(entry.name).toLowerCase()) ? [fullPath] : [];
  }).sort((left, right) => left.localeCompare(right));
}

function run(executable, args, maxBuffer = 32 * 1024 * 1024) {
  const result = spawnSync(executable, args, { windowsHide: true, maxBuffer, encoding: null });
  if (result.status !== 0) throw new Error("PHASE22_COLOR_PROCESS_FAILED");
  return result.stdout;
}

function probe(filePath) {
  const stdout = run(ffprobe, [
    "-v", "error", "-select_streams", "v:0", "-show_streams",
    "-show_entries", "frame=best_effort_timestamp_time", "-show_frames", "-of", "json", filePath,
  ], 64 * 1024 * 1024);
  const value = JSON.parse(stdout.toString("utf8"));
  const stream = value.streams[0];
  return {
    width: Number(stream.width),
    height: Number(stream.height),
    frames: value.frames.map((frame) => Number(frame.best_effort_timestamp_time)),
  };
}

function decode(filePath, ptsSeconds, pixelFormat, maxBuffer) {
  return run(ffmpeg, [
    "-v", "error", "-ss", String(ptsSeconds), "-noautorotate", "-i", filePath,
    "-map", "0:v:0", "-an", "-sn", "-dn", "-frames:v", "1",
    "-pix_fmt", pixelFormat, "-f", "rawvideo", "pipe:1",
  ], maxBuffer);
}

async function compare(window, yuv, rgba, width, height, profile) {
  return window.webContents.executeJavaScript(`(() => {
    const fromBase64 = (value) => Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
    const yuv = fromBase64(${JSON.stringify(yuv.toString("base64"))});
    const reference = fromBase64(${JSON.stringify(rgba.toString("base64"))});
    const width = ${width};
    const height = ${height};
    const chromaStride = Math.ceil(width / 2);
    const chromaBytes = chromaStride * Math.ceil(height / 2);
    const yBytes = width * height;
    const frame = new VideoFrame(yuv, {
      format: "I420", codedWidth: width, codedHeight: height, timestamp: 0,
      layout: [
        { offset: 0, stride: width },
        { offset: yBytes, stride: chromaStride },
        { offset: yBytes + chromaBytes, stride: chromaStride },
      ],
      colorSpace: ${JSON.stringify(profile)},
    });
    const canvas = document.createElement("canvas");
    canvas.width = width; canvas.height = height;
    const context = canvas.getContext("2d", { willReadFrequently: true });
    const startedAt = performance.now();
    try { context.drawImage(frame, 0, 0); } finally { frame.close(); }
    const drawMs = performance.now() - startedAt;
    const actual = context.getImageData(0, 0, width, height).data;
    const histogram = new Array(256).fill(0);
    let total = 0; let maximum = 0; let comparisons = 0;
    for (let index = 0; index < actual.length; index += 4) {
      for (let channel = 0; channel < 3; channel += 1) {
        const difference = Math.abs(actual[index + channel] - reference[index + channel]);
        histogram[difference] += 1; total += difference; comparisons += 1;
        if (difference > maximum) maximum = difference;
      }
    }
    const threshold = comparisons * 0.99;
    let cumulative = 0; let p99 = 0;
    for (; p99 < histogram.length; p99 += 1) { cumulative += histogram[p99]; if (cumulative >= threshold) break; }
    return { mean: total / comparisons, p99, max: maximum, drawMs, closed: frame.format === null };
  })()`);
}

async function compareWebgl(window, yuv, rgba, width, height, profile) {
  return window.webContents.executeJavaScript(`(() => {
    const fromBase64 = (value) => Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
    const source = fromBase64(${JSON.stringify(yuv.toString("base64"))});
    const reference = fromBase64(${JSON.stringify(rgba.toString("base64"))});
    const width = ${width}; const height = ${height};
    const cw = Math.ceil(width / 2); const ch = Math.ceil(height / 2);
    const yBytes = width * height; const cBytes = cw * ch;
    const canvas = document.createElement("canvas"); canvas.width = width; canvas.height = height;
    const gl = canvas.getContext("webgl2", { preserveDrawingBuffer: true });
    if (!gl) throw new Error("WEBGL2_UNAVAILABLE");
    const compile = (type, code) => { const shader = gl.createShader(type); gl.shaderSource(shader, code); gl.compileShader(shader); if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader)); return shader; };
    const vertex = compile(gl.VERTEX_SHADER, \`#version 300 es
      in vec2 position; in vec2 texCoord; out vec2 uv;
      void main(){ gl_Position=vec4(position,0.0,1.0); uv=texCoord; }\`);
    const fragment = compile(gl.FRAGMENT_SHADER, \`#version 300 es
      precision highp float; in vec2 uv; out vec4 color;
      uniform sampler2D yTex; uniform sampler2D uTex; uniform sampler2D vTex;
      void main(){
        vec2 chromaUv=uv+vec2(${profile.offsetX / width},${profile.offsetY / height});
        float y=(texture(yTex,uv).r*255.0-16.0)*1.16438356;
        float u=texture(uTex,chromaUv).r*255.0-128.0;
        float v=texture(vTex,chromaUv).r*255.0-128.0;
        color=vec4(clamp((vec3(y+1.59602678*v,y-0.39176229*u-0.81296765*v,y+2.01723214*u)+vec3(${profile.bias}))/255.0,0.0,1.0),1.0);
      }\`);
    const program = gl.createProgram(); gl.attachShader(program, vertex); gl.attachShader(program, fragment); gl.linkProgram(program); gl.useProgram(program);
    const positions = new Float32Array([-1,-1,1,-1,-1,1,1,1]);
    const coordinates = new Float32Array([0,1,1,1,0,0,1,0]);
    const attribute = (name, values) => { const buffer=gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER,buffer); gl.bufferData(gl.ARRAY_BUFFER,values,gl.STATIC_DRAW); const location=gl.getAttribLocation(program,name); gl.enableVertexAttribArray(location); gl.vertexAttribPointer(location,2,gl.FLOAT,false,0,0); };
    attribute("position",positions); attribute("texCoord",coordinates);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT,1);
    const plane = (unit, name, data, w, h, filter) => { const texture=gl.createTexture(); gl.activeTexture(gl.TEXTURE0+unit); gl.bindTexture(gl.TEXTURE_2D,texture); gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,filter); gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,filter); gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE); gl.texImage2D(gl.TEXTURE_2D,0,gl.R8,w,h,0,gl.RED,gl.UNSIGNED_BYTE,data); gl.uniform1i(gl.getUniformLocation(program,name),unit); };
    const chromaFilter=${profile.filter === "nearest" ? "gl.NEAREST" : "gl.LINEAR"};
    plane(0,"yTex",source.subarray(0,yBytes),width,height,gl.NEAREST);
    plane(1,"uTex",source.subarray(yBytes,yBytes+cBytes),cw,ch,chromaFilter);
    plane(2,"vTex",source.subarray(yBytes+cBytes,yBytes+cBytes*2),cw,ch,chromaFilter);
    const startedAt=performance.now(); gl.viewport(0,0,width,height); gl.drawArrays(gl.TRIANGLE_STRIP,0,4); gl.finish(); const drawMs=performance.now()-startedAt;
    const actual=new Uint8Array(width*height*4); gl.readPixels(0,0,width,height,gl.RGBA,gl.UNSIGNED_BYTE,actual);
    const histogram=new Array(256).fill(0); let total=0,maximum=0,comparisons=0;
    for(let y=0;y<height;y+=1){ for(let x=0;x<width;x+=1){ const ai=((height-1-y)*width+x)*4; const ri=(y*width+x)*4; for(let channel=0;channel<3;channel+=1){ const difference=Math.abs(actual[ai+channel]-reference[ri+channel]); histogram[difference]+=1; total+=difference; comparisons+=1; if(difference>maximum)maximum=difference; } } }
    const threshold=comparisons*0.99; let cumulative=0,p99=0; for(;p99<histogram.length;p99+=1){ cumulative+=histogram[p99]; if(cumulative>=threshold)break; }
    return { mean:total/comparisons,p99,max:maximum,drawMs,closed:true };
  })()`);
}

async function main() {
  await app.whenReady();
  const window = new BrowserWindow({ show: false, webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true } });
  await window.loadURL("data:text/html,<canvas></canvas>");
  const files = mediaFiles(root);
  if (files.length < 2) throw new Error(`PHASE22_NEEDS_MULTIPLE_SAMPLES_GOT_${files.length}`);
  const results = [];
  for (let sampleIndex = 0; sampleIndex < files.length; sampleIndex += 1) {
    const filePath = files[sampleIndex];
    const metadata = probe(filePath);
    const indexes = [...new Set([0, Math.floor(metadata.frames.length / 2), metadata.frames.length - 1])];
    const comparisons = [];
    for (const frameIndex of indexes) {
      const pts = metadata.frames[frameIndex];
      const yuv = decode(filePath, pts, "yuv420p", metadata.width * metadata.height * 2);
      const rgba = decode(filePath, pts, "rgba", metadata.width * metadata.height * 5);
      for (const profile of profiles) {
        comparisons.push({ frame: frameIndex === 0 ? "first" : frameIndex === metadata.frames.length - 1 ? "last" : "middle", profile: profile.name, ...(await compare(window, yuv, rgba, metadata.width, metadata.height, profile)) });
      }
      for (const profile of webglProfiles) {
        comparisons.push({ frame: frameIndex === 0 ? "first" : frameIndex === metadata.frames.length - 1 ? "last" : "middle", profile: profile.name, ...(await compareWebgl(window, yuv, rgba, metadata.width, metadata.height, profile)) });
      }
    }
    results.push({ sample: `Sample ${String.fromCharCode(65 + sampleIndex)}`, comparisons });
    process.stdout.write(`Sample ${String.fromCharCode(65 + sampleIndex)} color complete\n`);
  }
  const profileSummary = [...profiles.map((profile) => profile.name), ...webglProfiles.map((profile) => profile.name)].map((profileName) => {
    const values = results.flatMap((sample) => sample.comparisons.filter((value) => value.profile === profileName));
    return {
      profile: profileName,
      mean: Math.max(...values.map((value) => value.mean)),
      p99: Math.max(...values.map((value) => value.p99)),
      max: Math.max(...values.map((value) => value.max)),
      drawP95Ms: [...values.map((value) => value.drawMs)].sort((a, b) => a - b)[Math.floor(values.length * 0.95)],
      allClosed: values.every((value) => value.closed),
      passed: values.every((value) => value.mean <= 1 && value.p99 <= 2 && value.max <= 4 && value.closed),
    };
  });
  mkdirSync(path.dirname(outputPath), { recursive: true });
  writeFileSync(outputPath, `${JSON.stringify({ generatedAt: new Date().toISOString(), profileSummary, results }, null, 2)}\n`, "utf8");
  process.stdout.write(`${JSON.stringify(profileSummary, null, 2)}\n`);
  window.destroy();
  app.quit();
}

void main().catch((error) => { process.stderr.write(`${error.message}\n`); app.exit(1); });
