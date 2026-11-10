//! Drawing with Direct3D 11 into a flip-model swap chain.
//!
//! The video is uploaded as two textures (luma and chroma) and converted to RGB in a pixel
//! shader. The pointer is drawn on top from its own small texture. With tearing allowed
//! (the default), each frame goes to the screen immediately instead of waiting for the
//! monitor's next refresh.

use crate::protocol::{fit, PointerPosition, Rect};
use crate::session::{DecodedFrame, PointerImage};
use std::ffi::c_void;
use windows::core::{s, Interface, Result, PCSTR};
use windows::Win32::Foundation::{BOOL, HMODULE, HWND, RECT};
use windows::Win32::Graphics::Direct3D::Fxc::D3DCompile;
use windows::Win32::Graphics::Direct3D::*;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::Graphics::Gdi::{MonitorFromWindow, MONITOR_DEFAULTTONEAREST};
use windows::Win32::UI::WindowsAndMessaging::GetClientRect;

/// A full-screen triangle; the viewport decides where it lands.
const VERTEX_SHADER: &str = r#"
struct Output { float4 position : SV_Position; float2 uv : TEXCOORD0; };
Output main(uint id : SV_VertexID) {
    Output o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.uv = uv;
    o.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return o;
}
"#;

/// NV12, video range, BT.709 (what the Mac's encoder produces) to RGB.
const VIDEO_PIXEL_SHADER: &str = r#"
Texture2D<float> luma : register(t0);
Texture2D<float2> chroma : register(t1);
SamplerState linearSampler : register(s0);
float4 main(float4 position : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    float y = (luma.Sample(linearSampler, uv) - 16.0 / 255.0) * (255.0 / 219.0);
    float2 c = (chroma.Sample(linearSampler, uv) - 128.0 / 255.0) * (255.0 / 224.0);
    float3 rgb = float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x);
    return float4(saturate(rgb), 1.0);
}
"#;

const POINTER_PIXEL_SHADER: &str = r#"
Texture2D<float4> image : register(t0);
SamplerState linearSampler : register(s0);
float4 main(float4 position : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    return image.Sample(linearSampler, uv);
}
"#;

struct VideoPlanes {
    width: u32,
    height: u32,
    luma: ID3D11Texture2D,
    chroma: ID3D11Texture2D,
    luma_view: ID3D11ShaderResourceView,
    chroma_view: ID3D11ShaderResourceView,
}

struct Pointer {
    view: ID3D11ShaderResourceView,
    width: f32,
    height: f32,
    hot_x: f32,
    hot_y: f32,
}

pub struct Renderer {
    hwnd: HWND,
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    swap_chain: IDXGISwapChain1,
    swap_chain_flags: u32,
    target: Option<ID3D11RenderTargetView>,
    size: (u32, u32),
    allow_tearing: bool,
    vsync: bool,
    vertex_shader: ID3D11VertexShader,
    video_shader: ID3D11PixelShader,
    pointer_shader: ID3D11PixelShader,
    sampler: ID3D11SamplerState,
    blend: ID3D11BlendState,
    video: Option<VideoPlanes>,
    pointer_image: Option<Pointer>,
    pointer: Option<PointerPosition>,
}

impl Renderer {
    pub fn new(hwnd: isize, vsync: bool) -> Result<Renderer> {
        let hwnd = HWND(hwnd as *mut c_void);
        unsafe {
            let factory: IDXGIFactory2 = CreateDXGIFactory1()?;

            // Use the graphics card the window's monitor is plugged into, so frames
            // aren't copied between cards.
            let adapter: Option<IDXGIAdapter> = adapter_for_window(&factory, hwnd).and_then(|a| a.cast().ok());
            let driver_type = if adapter.is_some() { D3D_DRIVER_TYPE_UNKNOWN } else { D3D_DRIVER_TYPE_HARDWARE };
            let mut device = None;
            let mut context = None;
            D3D11CreateDevice(
                adapter.as_ref(),
                driver_type,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                Some(&[D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1]),
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )?;
            let device: ID3D11Device = device.expect("D3D11CreateDevice returned no device");
            let context: ID3D11DeviceContext = context.expect("D3D11CreateDevice returned no context");

            let allow_tearing = tearing_supported(&factory);
            let swap_chain_flags = if allow_tearing { DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING.0 as u32 } else { 0 };
            let description = DXGI_SWAP_CHAIN_DESC1 {
                Width: 0,
                Height: 0,
                Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                Stereo: BOOL(0),
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
                BufferCount: 2,
                Scaling: DXGI_SCALING_STRETCH,
                SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
                AlphaMode: DXGI_ALPHA_MODE_IGNORE,
                Flags: swap_chain_flags,
            };
            let swap_chain = factory.CreateSwapChainForHwnd(&device, hwnd, &description, None, None)?;
            // Queue at most one frame ahead.
            if let Ok(dxgi_device) = device.cast::<IDXGIDevice1>() {
                let _ = dxgi_device.SetMaximumFrameLatency(1);
            }

            let vertex_code = compile(VERTEX_SHADER, s!("vs_5_0"))?;
            let mut vertex_shader = None;
            device.CreateVertexShader(&vertex_code, None, Some(&mut vertex_shader))?;
            let video_shader = pixel_shader(&device, VIDEO_PIXEL_SHADER)?;
            let pointer_shader = pixel_shader(&device, POINTER_PIXEL_SHADER)?;

            let sampler_description = D3D11_SAMPLER_DESC {
                Filter: D3D11_FILTER_MIN_MAG_MIP_LINEAR,
                AddressU: D3D11_TEXTURE_ADDRESS_CLAMP,
                AddressV: D3D11_TEXTURE_ADDRESS_CLAMP,
                AddressW: D3D11_TEXTURE_ADDRESS_CLAMP,
                MipLODBias: 0.0,
                MaxAnisotropy: 1,
                ComparisonFunc: D3D11_COMPARISON_NEVER,
                BorderColor: [0.0; 4],
                MinLOD: 0.0,
                MaxLOD: f32::MAX,
            };
            let mut sampler = None;
            device.CreateSamplerState(&sampler_description, Some(&mut sampler))?;

            let mut blend_description = D3D11_BLEND_DESC::default();
            blend_description.RenderTarget[0] = D3D11_RENDER_TARGET_BLEND_DESC {
                BlendEnable: BOOL(1),
                SrcBlend: D3D11_BLEND_SRC_ALPHA,
                DestBlend: D3D11_BLEND_INV_SRC_ALPHA,
                BlendOp: D3D11_BLEND_OP_ADD,
                SrcBlendAlpha: D3D11_BLEND_ONE,
                DestBlendAlpha: D3D11_BLEND_ZERO,
                BlendOpAlpha: D3D11_BLEND_OP_ADD,
                RenderTargetWriteMask: D3D11_COLOR_WRITE_ENABLE_ALL.0 as u8,
            };
            let mut blend = None;
            device.CreateBlendState(&blend_description, Some(&mut blend))?;

            Ok(Renderer {
                hwnd,
                device,
                context,
                swap_chain,
                swap_chain_flags,
                target: None,
                size: (0, 0),
                allow_tearing,
                vsync,
                vertex_shader: vertex_shader.expect("no vertex shader"),
                video_shader,
                pointer_shader,
                sampler: sampler.expect("no sampler"),
                blend: blend.expect("no blend state"),
                video: None,
                pointer_image: None,
                pointer: None,
            })
        }
    }

    pub fn upload_video(&mut self, frame: &DecodedFrame) -> Result<()> {
        let needs_new_planes = self.video.as_ref().map_or(true, |v| v.width != frame.width || v.height != frame.height);
        if needs_new_planes {
            self.video = Some(self.create_planes(frame.width, frame.height)?);
        }
        let Some(video) = &self.video else { return Ok(()) };
        unsafe {
            self.context.UpdateSubresource(&video.luma, 0, None, frame.data.as_ptr() as *const c_void, frame.stride, 0);
            self.context.UpdateSubresource(
                &video.chroma,
                0,
                None,
                frame.data[frame.chroma_offset..].as_ptr() as *const c_void,
                frame.stride,
                0,
            );
        }
        Ok(())
    }

    pub fn set_pointer(&mut self, position: PointerPosition) {
        self.pointer = Some(position);
    }

    pub fn set_pointer_image(&mut self, image: &PointerImage) -> Result<()> {
        let description = texture_description(image.pixel_width, image.pixel_height, DXGI_FORMAT_R8G8B8A8_UNORM);
        let initial = D3D11_SUBRESOURCE_DATA {
            pSysMem: image.rgba.as_ptr() as *const c_void,
            SysMemPitch: image.pixel_width * 4,
            SysMemSlicePitch: 0,
        };
        unsafe {
            let mut texture = None;
            self.device.CreateTexture2D(&description, Some(&initial), Some(&mut texture))?;
            let texture = texture.expect("no pointer texture");
            let mut view = None;
            self.device.CreateShaderResourceView(&texture, None, Some(&mut view))?;
            self.pointer_image = Some(Pointer {
                view: view.expect("no pointer view"),
                width: image.width,
                height: image.height,
                hot_x: image.hot_x,
                hot_y: image.hot_y,
            });
        }
        Ok(())
    }

    /// Draws the latest video frame and the pointer, and shows them.
    pub fn present(&mut self) -> Result<()> {
        self.resize_if_needed()?;
        let Some(target) = self.target.clone() else { return Ok(()) };
        unsafe {
            let context = &self.context;
            context.ClearRenderTargetView(&target, &[0.0, 0.0, 0.0, 1.0]);
            context.OMSetRenderTargets(Some(&[Some(target)]), None);
            context.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            context.VSSetShader(&self.vertex_shader, None);
            context.PSSetSamplers(0, Some(&[Some(self.sampler.clone())]));

            if let Some(video) = &self.video {
                let area = fit(video.width, video.height, self.size.0, self.size.1);
                context.RSSetViewports(Some(&[viewport(area)]));
                context.OMSetBlendState(None, None, u32::MAX);
                context.PSSetShader(&self.video_shader, None);
                context
                    .PSSetShaderResources(0, Some(&[Some(video.luma_view.clone()), Some(video.chroma_view.clone())]));
                context.Draw(3, 0);

                if let (Some(position), Some(pointer)) = (self.pointer, &self.pointer_image) {
                    if position.visible {
                        let scale = area.width / video.width as f32;
                        let rect = Rect {
                            x: area.x + (position.x as f32 - pointer.hot_x) * scale,
                            y: area.y + (position.y as f32 - pointer.hot_y) * scale,
                            width: pointer.width * scale,
                            height: pointer.height * scale,
                        };
                        context.RSSetViewports(Some(&[viewport(rect)]));
                        context.OMSetBlendState(&self.blend, None, u32::MAX);
                        context.PSSetShader(&self.pointer_shader, None);
                        context.PSSetShaderResources(0, Some(&[Some(pointer.view.clone())]));
                        context.Draw(3, 0);
                    }
                }
            }

            let (interval, flags) = if self.vsync {
                (1, DXGI_PRESENT(0))
            } else if self.allow_tearing {
                (0, DXGI_PRESENT_ALLOW_TEARING)
            } else {
                (0, DXGI_PRESENT(0))
            };
            self.swap_chain.Present(interval, flags).ok()
        }
    }

    fn resize_if_needed(&mut self) -> Result<()> {
        let mut client = RECT::default();
        unsafe { GetClientRect(self.hwnd, &mut client)? };
        let size = ((client.right - client.left).max(1) as u32, (client.bottom - client.top).max(1) as u32);
        if size == self.size && self.target.is_some() {
            return Ok(());
        }
        unsafe {
            self.target = None;
            self.context.OMSetRenderTargets(None, None);
            self.context.Flush();
            self.swap_chain.ResizeBuffers(
                0,
                size.0,
                size.1,
                DXGI_FORMAT_UNKNOWN,
                DXGI_SWAP_CHAIN_FLAG(self.swap_chain_flags as i32),
            )?;
            let back_buffer: ID3D11Texture2D = self.swap_chain.GetBuffer(0)?;
            let mut target = None;
            self.device.CreateRenderTargetView(&back_buffer, None, Some(&mut target))?;
            self.target = target;
        }
        self.size = size;
        Ok(())
    }

    fn create_planes(&self, width: u32, height: u32) -> Result<VideoPlanes> {
        let (luma, luma_view) = self.plane(width, height, DXGI_FORMAT_R8_UNORM)?;
        let (chroma, chroma_view) = self.plane(width / 2, height / 2, DXGI_FORMAT_R8G8_UNORM)?;
        Ok(VideoPlanes { width, height, luma, chroma, luma_view, chroma_view })
    }

    fn plane(
        &self,
        width: u32,
        height: u32,
        format: DXGI_FORMAT,
    ) -> Result<(ID3D11Texture2D, ID3D11ShaderResourceView)> {
        let description = texture_description(width, height, format);
        unsafe {
            let mut texture = None;
            self.device.CreateTexture2D(&description, None, Some(&mut texture))?;
            let texture = texture.expect("no texture");
            let mut view = None;
            self.device.CreateShaderResourceView(&texture, None, Some(&mut view))?;
            Ok((texture, view.expect("no texture view")))
        }
    }
}

fn texture_description(width: u32, height: u32, format: DXGI_FORMAT) -> D3D11_TEXTURE2D_DESC {
    D3D11_TEXTURE2D_DESC {
        Width: width.max(1),
        Height: height.max(1),
        MipLevels: 1,
        ArraySize: 1,
        Format: format,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        Usage: D3D11_USAGE_DEFAULT,
        BindFlags: D3D11_BIND_SHADER_RESOURCE.0 as u32,
        CPUAccessFlags: 0,
        MiscFlags: 0,
    }
}

fn viewport(rect: Rect) -> D3D11_VIEWPORT {
    D3D11_VIEWPORT {
        TopLeftX: rect.x,
        TopLeftY: rect.y,
        Width: rect.width,
        Height: rect.height,
        MinDepth: 0.0,
        MaxDepth: 1.0,
    }
}

/// The adapter driving the monitor the window is on, if it can be found.
fn adapter_for_window(factory: &IDXGIFactory2, hwnd: HWND) -> Option<IDXGIAdapter1> {
    unsafe {
        let monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        let mut adapter_index = 0;
        while let Ok(adapter) = factory.EnumAdapters1(adapter_index) {
            let mut output_index = 0;
            while let Ok(output) = adapter.EnumOutputs(output_index) {
                if let Ok(description) = output.GetDesc() {
                    if description.Monitor == monitor {
                        return Some(adapter);
                    }
                }
                output_index += 1;
            }
            adapter_index += 1;
        }
        None
    }
}

fn tearing_supported(factory: &IDXGIFactory2) -> bool {
    let Ok(factory5) = factory.cast::<IDXGIFactory5>() else { return false };
    let mut allowed = BOOL(0);
    let result = unsafe {
        factory5.CheckFeatureSupport(
            DXGI_FEATURE_PRESENT_ALLOW_TEARING,
            &mut allowed as *mut BOOL as *mut c_void,
            std::mem::size_of::<BOOL>() as u32,
        )
    };
    result.is_ok() && allowed.as_bool()
}

fn pixel_shader(device: &ID3D11Device, source: &str) -> Result<ID3D11PixelShader> {
    let code = compile(source, s!("ps_5_0"))?;
    let mut shader = None;
    unsafe { device.CreatePixelShader(&code, None, Some(&mut shader))? };
    Ok(shader.expect("no pixel shader"))
}

/// Compiles HLSL with the system's shader compiler (d3dcompiler_47.dll, part of Windows 10+).
fn compile(source: &str, target: PCSTR) -> Result<Vec<u8>> {
    let mut code = None;
    let mut errors = None;
    let result = unsafe {
        D3DCompile(
            source.as_ptr() as *const c_void,
            source.len(),
            PCSTR::null(),
            None,
            None,
            s!("main"),
            target,
            0,
            0,
            &mut code,
            Some(&mut errors),
        )
    };
    if let Err(e) = result {
        if let Some(errors) = errors {
            let message = unsafe { blob_bytes(&errors) };
            eprintln!("Shader error: {}", String::from_utf8_lossy(message));
        }
        return Err(e);
    }
    let code = code.expect("no shader code");
    Ok(unsafe { blob_bytes(&code) }.to_vec())
}

unsafe fn blob_bytes(blob: &ID3DBlob) -> &[u8] {
    std::slice::from_raw_parts(blob.GetBufferPointer() as *const u8, blob.GetBufferSize())
}
