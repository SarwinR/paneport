//! H.264 decoding with Windows' built-in Media Foundation decoder, in low-latency mode
//! (one frame in, one frame out, no buffering ahead).
//!
//! This first version decodes on the CPU (the decoder is multi-threaded and fast at 1080p)
//! and the renderer uploads the result. Decoding straight into GPU memory (DXVA) is the
//! natural next step for 4K streams.

use crate::session::{now_ms, DecodedFrame, EncodedFrame, FrameTiming, RenderEvent, Shared};
use std::collections::HashMap;
use std::mem::ManuallyDrop;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::Arc;
use std::thread;
use windows::core::{Interface, Result};
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
};

/// Starts a decoder thread for a `width` × `height` stream and returns where to send frames.
/// The thread ends when the returned sender is dropped.
pub fn spawn(
    width: u32,
    height: u32,
    shared: Arc<Shared>,
    render: Sender<RenderEvent>,
    outbox: Sender<String>,
    backlog: Arc<AtomicUsize>,
) -> Sender<EncodedFrame> {
    let (frames_tx, frames_rx) = mpsc::channel::<EncodedFrame>();
    let name = shared.name.clone();
    let _ = thread::Builder::new().name(format!("decoder: {name}")).spawn(move || {
        if let Err(e) = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED).ok() } {
            eprintln!("{name}: couldn't start COM: {e}");
            return;
        }
        if let Err(e) = unsafe { MFStartup(MF_VERSION, MFSTARTUP_FULL) } {
            eprintln!("{name}: couldn't start Media Foundation: {e}");
            return;
        }
        match H264Decoder::new(width, height) {
            Ok(mut decoder) => {
                let mut waiting_for_keyframe = true;
                for frame in frames_rx {
                    backlog.fetch_sub(1, Ordering::SeqCst);
                    if waiting_for_keyframe && !frame.is_keyframe {
                        continue;
                    }
                    match decoder.decode(&frame.data, frame.timing) {
                        Ok(decoded) => {
                            waiting_for_keyframe = false;
                            for frame in decoded {
                                if render.send(RenderEvent::Video(frame)).is_err() {
                                    break;
                                }
                            }
                        }
                        Err(e) => {
                            eprintln!("{name}: decoding failed ({e}); asking for a keyframe");
                            waiting_for_keyframe = true;
                            let _ = outbox.send("k".to_string());
                        }
                    }
                }
            }
            Err(e) => eprintln!("{name}: couldn't create the H.264 decoder: {e}"),
        }
        unsafe {
            let _ = MFShutdown();
            CoUninitialize();
        }
    });
    frames_tx
}

struct H264Decoder {
    transform: IMFTransform,
    /// The stream's visible size.
    width: u32,
    height: u32,
    /// The decoder's output size, which can be padded (1080 → 1088 rows).
    frame_width: u32,
    frame_height: u32,
    /// Whether the decoder allocates output samples itself.
    provides_samples: bool,
    output_buffer_size: u32,
    /// Sample time (a frame counter) → timing, to match outputs to inputs.
    timings: HashMap<i64, FrameTiming>,
    next_time: i64,
}

impl H264Decoder {
    fn new(width: u32, height: u32) -> Result<H264Decoder> {
        unsafe {
            let transform: IMFTransform = CoCreateInstance(&CLSID_MSH264DecoderMFT, None, CLSCTX_INPROC_SERVER)?;
            if let Ok(attributes) = transform.GetAttributes() {
                let _ = attributes.SetUINT32(&MF_LOW_LATENCY, 1);
            }

            let input = MFCreateMediaType()?;
            input.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            input.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_H264)?;
            input.SetUINT64(&MF_MT_FRAME_SIZE, pack_size(width, height))?;
            input.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
            transform.SetInputType(0, &input, 0)?;

            let mut decoder = H264Decoder {
                transform,
                width,
                height,
                frame_width: width,
                frame_height: height,
                provides_samples: true,
                output_buffer_size: 0,
                timings: HashMap::new(),
                next_time: 0,
            };
            decoder.select_output_type()?;
            decoder.transform.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)?;
            decoder.transform.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)?;
            Ok(decoder)
        }
    }

    /// Picks NV12 output. Called at start and whenever the decoder reports a format change.
    fn select_output_type(&mut self) -> Result<()> {
        unsafe {
            let mut index = 0;
            loop {
                let candidate = self.transform.GetOutputAvailableType(0, index)?;
                if candidate.GetGUID(&MF_MT_SUBTYPE)? == MFVideoFormat_NV12 {
                    self.transform.SetOutputType(0, &candidate, 0)?;
                    if let Ok(size) = candidate.GetUINT64(&MF_MT_FRAME_SIZE) {
                        self.frame_width = (size >> 32) as u32;
                        self.frame_height = size as u32;
                    }
                    let info = self.transform.GetOutputStreamInfo(0)?;
                    let provides =
                        MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 as u32 | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES.0 as u32;
                    self.provides_samples = info.dwFlags & provides != 0;
                    self.output_buffer_size = info.cbSize;
                    return Ok(());
                }
                index += 1;
            }
        }
    }

    fn decode(&mut self, data: &[u8], timing: FrameTiming) -> Result<Vec<DecodedFrame>> {
        unsafe {
            let sample = MFCreateSample()?;
            let buffer = MFCreateMemoryBuffer(data.len() as u32)?;
            let mut destination = std::ptr::null_mut();
            buffer.Lock(&mut destination, None, None)?;
            std::ptr::copy_nonoverlapping(data.as_ptr(), destination, data.len());
            buffer.Unlock()?;
            buffer.SetCurrentLength(data.len() as u32)?;
            sample.AddBuffer(&buffer)?;

            self.next_time += 1;
            sample.SetSampleTime(self.next_time)?;
            self.timings.insert(self.next_time, timing);
            if self.timings.len() > 64 {
                let oldest = self.next_time - 64;
                self.timings.retain(|&time, _| time > oldest);
            }

            let mut decoded = Vec::new();
            if let Err(e) = self.transform.ProcessInput(0, &sample, 0) {
                if e.code() != MF_E_NOTACCEPTING {
                    return Err(e);
                }
                // Full: take what's ready, then try again.
                self.drain(&mut decoded)?;
                self.transform.ProcessInput(0, &sample, 0)?;
            }
            self.drain(&mut decoded)?;
            Ok(decoded)
        }
    }

    /// Collects every frame the decoder has ready.
    fn drain(&mut self, decoded: &mut Vec<DecodedFrame>) -> Result<()> {
        unsafe {
            loop {
                let provided = if self.provides_samples {
                    None
                } else {
                    let sample = MFCreateSample()?;
                    sample.AddBuffer(&MFCreateMemoryBuffer(self.output_buffer_size)?)?;
                    Some(sample)
                };
                let mut output = [MFT_OUTPUT_DATA_BUFFER {
                    dwStreamID: 0,
                    pSample: ManuallyDrop::new(provided),
                    dwStatus: 0,
                    pEvents: ManuallyDrop::new(None),
                }];
                let mut status = 0u32;
                let result = self.transform.ProcessOutput(0, &mut output, &mut status);
                let sample = ManuallyDrop::take(&mut output[0].pSample);
                drop(ManuallyDrop::take(&mut output[0].pEvents));

                match result {
                    Ok(()) => {
                        if let Some(sample) = sample {
                            if let Some(frame) = self.read_frame(&sample)? {
                                decoded.push(frame);
                            }
                        }
                    }
                    Err(e) if e.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => return Ok(()),
                    Err(e) if e.code() == MF_E_TRANSFORM_STREAM_CHANGE => self.select_output_type()?,
                    Err(e) => return Err(e),
                }
            }
        }
    }

    /// Copies the visible part of an NV12 output sample.
    fn read_frame(&mut self, sample: &IMFSample) -> Result<Option<DecodedFrame>> {
        unsafe {
            let timing = sample.GetSampleTime().ok().and_then(|time| self.timings.remove(&time));
            let width = self.width.min(self.frame_width);
            let height = self.height.min(self.frame_height) & !1;

            let buffer = sample.GetBufferByIndex(0)?;
            // A 2D buffer tells us its real row pitch; otherwise assume rows are frame_width wide.
            let (base, pitch, locked_2d) = match buffer.cast::<IMF2DBuffer>() {
                Ok(buffer_2d) => {
                    let mut scanline = std::ptr::null_mut();
                    let mut pitch = 0i32;
                    buffer_2d.Lock2D(&mut scanline, &mut pitch)?;
                    (scanline as *const u8, pitch.unsigned_abs() as usize, Some(buffer_2d))
                }
                Err(_) => {
                    let mut pointer = std::ptr::null_mut();
                    buffer.Lock(&mut pointer, None, None)?;
                    (pointer as *const u8, self.frame_width as usize, None)
                }
            };

            // Luma rows, then chroma rows starting after the decoder's padded height.
            let luma_size = pitch * height as usize;
            let chroma_size = pitch * (height as usize / 2);
            let mut data = Vec::with_capacity(luma_size + chroma_size);
            data.extend_from_slice(std::slice::from_raw_parts(base, luma_size));
            let chroma = base.add(pitch * self.frame_height as usize);
            data.extend_from_slice(std::slice::from_raw_parts(chroma, chroma_size));

            match locked_2d {
                Some(buffer_2d) => buffer_2d.Unlock2D()?,
                None => buffer.Unlock()?,
            }

            Ok(Some(DecodedFrame {
                width,
                height,
                stride: pitch as u32,
                data,
                chroma_offset: luma_size,
                timing,
                decoded_ms: now_ms(),
            }))
        }
    }
}

fn pack_size(width: u32, height: u32) -> u64 {
    ((width as u64) << 32) | height as u64
}
