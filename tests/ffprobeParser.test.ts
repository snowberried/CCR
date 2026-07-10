import assert from "node:assert/strict";
import test from "node:test";
import {
  FfprobeParseError,
  parseFfprobeOutput,
} from "../electron/adapters/ffprobe/parseFfprobeOutput";

function stringify(value: unknown): string {
  return JSON.stringify(value);
}

test("parses the first video stream and ignores frames from other streams", () => {
  const result = parseFfprobeOutput(
    stringify({
      format: { format_name: "mov,mp4,m4a,3gp,3g2,mj2" },
      streams: [
        { index: 0, codec_type: "audio" },
        {
          index: 1,
          codec_type: "video",
          codec_name: "h264",
          width: 406,
          height: 720,
          time_base: "1/12288",
          r_frame_rate: "24/1",
          avg_frame_rate: "24/1",
          duration: "119.0",
          nb_frames: "3",
          side_data_list: [{ rotation: -90 }],
        },
      ],
      frames: [
        { media_type: "audio", stream_index: 0, pts: "0", pts_time: "0" },
        {
          media_type: "video",
          stream_index: 1,
          key_frame: 1,
          best_effort_timestamp: "0",
          best_effort_timestamp_time: "0.000000",
          pkt_duration_time: "0.041667",
        },
        {
          media_type: "video",
          stream_index: 1,
          key_frame: 0,
          best_effort_timestamp: "512",
          pts: "999",
          best_effort_timestamp_time: "0.041667",
          pts_time: "9.99",
          pkt_duration_time: "0.041667",
        },
        {
          media_type: "video",
          stream_index: 1,
          key_frame: 0,
          pts: "1024",
          pts_time: "0.083333",
        },
      ],
    }),
  );

  assert.equal(result.containerFormat, "mov,mp4,m4a,3gp,3g2,mj2");
  assert.deepEqual(result.stream, {
    streamIndex: 1,
    codecName: "h264",
    width: 406,
    height: 720,
    timeBase: { numerator: 1, denominator: 12288 },
    nominalFrameRate: { numerator: 24, denominator: 1 },
    averageFrameRate: { numerator: 24, denominator: 1 },
    durationSeconds: 119,
    reportedFrameCount: 3,
    rotationDegrees: -90,
  });
  assert.deepEqual(
    result.frames.map((frame) => ({ frameIndex: frame.frameIndex, pts: frame.pts })),
    [
      { frameIndex: 0, pts: "0" },
      { frameIndex: 1, pts: "512" },
      { frameIndex: 2, pts: "1024" },
    ],
  );
  assert.equal(result.frames[1].ptsSeconds, 0.041667);
  assert.equal(result.frames[2].durationSeconds, null);
  assert.equal(result.validation.issues.length, 0);
});

test("keeps absent optional metadata null instead of inferring from FPS", () => {
  const result = parseFfprobeOutput(
    stringify({
      streams: [
        {
          index: "0",
          codec_type: "video",
          width: "640",
          height: "480",
          time_base: "N/A",
          r_frame_rate: "0/0",
          avg_frame_rate: "N/A",
          duration: "N/A",
          nb_frames: "N/A",
          tags: { rotate: "N/A" },
        },
      ],
      frames: [],
    }),
  );

  assert.equal(result.containerFormat, null);
  assert.equal(result.stream.codecName, null);
  assert.equal(result.stream.timeBase, null);
  assert.equal(result.stream.nominalFrameRate, null);
  assert.equal(result.stream.averageFrameRate, null);
  assert.equal(result.stream.durationSeconds, null);
  assert.equal(result.stream.reportedFrameCount, null);
  assert.equal(result.stream.rotationDegrees, null);
});

test("preserves variable frame duration entries", () => {
  const result = parseFfprobeOutput(
    stringify({
      streams: [{ index: 0, codec_type: "video", width: 640, height: 480 }],
      frames: [
        {
          media_type: "video",
          stream_index: 0,
          pts: "0",
          pts_time: "0",
          pkt_duration_time: "0.04",
        },
        {
          media_type: "video",
          stream_index: 0,
          pts: "1",
          pts_time: "0.04",
          duration_time: "0.08",
        },
      ],
    }),
  );

  assert.deepEqual(
    result.frames.map((frame) => frame.durationSeconds),
    [0.04, 0.08],
  );
});

test("passes missing, invalid, duplicate, and backward raw PTS to domain validation", () => {
  const result = parseFfprobeOutput(
    stringify({
      streams: [{ index: 0, codec_type: "video", width: 640, height: 480 }],
      frames: [
        { media_type: "video", stream_index: 0, pts: "2", pts_time: "0.08" },
        { media_type: "video", stream_index: 0, pts: "02", pts_time: "0.080001" },
        { media_type: "video", stream_index: 0, pts: "1", pts_time: "0.04" },
        { media_type: "video", stream_index: 0 },
        { media_type: "video", stream_index: 0, pts: "bad", pts_time: "0.12" },
      ],
    }),
  );

  assert.deepEqual(
    result.validation.issues.map((issue) => issue.code),
    ["PTS_DUPLICATE", "PTS_BACKWARD", "PTS_MISSING", "PTS_INVALID"],
  );
});

test("rejects invalid JSON and output without a video stream", () => {
  assert.throws(
    () => parseFfprobeOutput("not-json"),
    (error) => error instanceof FfprobeParseError && error.code === "INVALID_JSON",
  );
  assert.throws(
    () => parseFfprobeOutput(stringify({ streams: [{ index: 0, codec_type: "audio" }] })),
    (error) => error instanceof FfprobeParseError && error.code === "VIDEO_STREAM_NOT_FOUND",
  );
  assert.throws(
    () => parseFfprobeOutput(stringify({ streams: [] })),
    (error) => error instanceof FfprobeParseError && error.code === "VIDEO_STREAM_NOT_FOUND",
  );
});
