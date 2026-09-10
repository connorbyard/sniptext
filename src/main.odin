package main

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import sdl "vendor:sdl3"
import stb "vendor:stb/image"



Vec2 :: struct {
        x: f32,
        y: f32,
}

Rect :: struct {
        x:      f32,
        y:      f32,
        width:  f32,
        height: f32,
}

State :: struct {
        window:   ^sdl.Window,
        renderer: ^sdl.Renderer,
        running:  bool,

        window_width:  i32,
        window_height: i32,

        image_pixels:  []u8,
        image_texture: ^sdl.Texture,
        image_width:   i32,
        image_height:  i32,
        image_rect:    Rect,
        image_loaded:  bool,

        mouse_position: Vec2,

        mouse_left_down:     bool,
        mouse_left_pressed:  bool,
        mouse_left_released: bool,

        selection_active: bool,
        selection_start:  Vec2,
        selection_rect:   Rect,

        ocr_text:    string,
        status_text: string,
}

state: State


// --------------------------------------------------------------------------------------------------------------------
// RECT PRIMITIVES
// --------------------------------------------------------------------------------------------------------------------

rect_from_points :: proc(a, b: Vec2) -> Rect {
        x := min(a.x, b.x)
        y := min(a.y, b.y)

        return Rect{
                x,
                y,
                abs(b.x - a.x),
                abs(b.y - a.y),
        }
}

rect_contains_point :: proc(rect: Rect, point: Vec2) -> bool {
        return point.x >= rect.x &&
               point.x < rect.x + rect.width &&
               point.y >= rect.y &&
               point.y < rect.y + rect.height
}

rect_clamp_point :: proc(rect: Rect, point: Vec2) -> Vec2 {
        return Vec2{
                clamp(point.x, rect.x, rect.x + rect.width),
                clamp(point.y, rect.y, rect.y + rect.height),
        }
}

rect_fit_inside :: proc(source_width, source_height: f32, bounds: Rect) -> Rect {
        if source_width <= 0 || source_height <= 0 {
                return Rect{}
        }

        scale_x := bounds.width  / source_width
        scale_y := bounds.height / source_height
        scale   := min(scale_x, scale_y)

        width  := source_width  * scale
        height := source_height * scale

        x := bounds.x + (bounds.width  - width)  * 0.5
        y := bounds.y + (bounds.height - height) * 0.5

        return Rect{
                x,
                y,
                width,
                height,
        }
}

rect_remap_point :: proc(source: Rect, destination: Rect, point: Vec2) -> Vec2 {
        x := (point.x - source.x) / source.width
        y := (point.y - source.y) / source.height

        return Vec2{
                destination.x + x * destination.width,
                destination.y + y * destination.height,
        }
}

rect_to_pixel_bounds :: proc(rect: Rect) -> (x, y, width, height: i32) {
        x0 := i32(math.floor(rect.x))
        y0 := i32(math.floor(rect.y))
        x1 := i32(math.ceil(rect.x + rect.width))
        y1 := i32(math.ceil(rect.y + rect.height))

        return x0, y0, x1 - x0, y1 - y0
}


// --------------------------------------------------------------------------------------------------------------------
// WINDOW PRIMITIVES
// --------------------------------------------------------------------------------------------------------------------

window_initialise :: proc(title: cstring, width, height: i32) -> bool {
        if !sdl.Init({.VIDEO}) {
                return false
        }

        if !sdl.CreateWindowAndRenderer(title, width, height, {.RESIZABLE}, &state.window, &state.renderer) {
                sdl.Quit()
                return false
        }

        state.running       = true
        state.window_width  = width
        state.window_height = height

        return true
}

window_shutdown :: proc() {
        if state.renderer != nil {
                sdl.DestroyRenderer(state.renderer)
        }

        if state.window != nil {
                sdl.DestroyWindow(state.window)
        }

        sdl.Quit()
}

window_poll_events :: proc() {
        state.mouse_left_pressed  = false
        state.mouse_left_released = false

        event: sdl.Event

        for sdl.PollEvent(&event) {
                #partial switch event.type {
                case .QUIT:
                        state.running = false

                case .WINDOW_RESIZED:
                        state.window_width  = event.window.data1
                        state.window_height = event.window.data2

                case .MOUSE_MOTION:
                        state.mouse_position.x = event.motion.x
                        state.mouse_position.y = event.motion.y

                case .MOUSE_BUTTON_DOWN:
                        if event.button.button == sdl.BUTTON_LEFT {
                                state.mouse_left_down    = true
                                state.mouse_left_pressed = true
                        }

                case .MOUSE_BUTTON_UP:
                        if event.button.button == sdl.BUTTON_LEFT {
                                state.mouse_left_down     = false
                                state.mouse_left_released = true
                        }

                case .DROP_FILE:
                        if image_load(event.drop.data) {
                                fmt.println("Loaded:", state.image_width, "x", state.image_height)
                        }
                }
        }
}

window_draw_drop_message :: proc() {
        if state.image_loaded {
                return
        }

        text: cstring = "[ DROP IMAGE HERE ]"
        text_width := f32(19 * 8)

        x := (f32(state.window_width) - text_width) * 0.5
        y := (f32(state.window_height) - 8) * 0.5

        sdl.SetRenderDrawColor(state.renderer, 128, 128, 128, 255)
        sdl.RenderDebugText(state.renderer, x, y, text)
}

// --------------------------------------------------------------------------------------------------------------------
// IMAGE PRIMITIVES
// --------------------------------------------------------------------------------------------------------------------

image_load :: proc(path: cstring) -> bool {
        image_unload()

        width:    c.int
        height:   c.int
        channels: c.int

        pixels := stb.load(path, &width, &height, &channels, 4)
        if pixels == nil {
                return false
        }

        state.image_width  = i32(width)
        state.image_height = i32(height)
        state.image_pixels = pixels[:int(width * height * 4)]

        if !image_create_texture() {
                image_unload()
                return false
        }

        state.image_loaded = true
        return true
}

image_unload :: proc() {
        if state.image_texture != nil {
                sdl.DestroyTexture(state.image_texture)
                state.image_texture = nil
        }

        if state.image_pixels != nil {
                stb.image_free(raw_data(state.image_pixels))
                state.image_pixels = nil
        }

        state.image_width  = 0
        state.image_height = 0
        state.image_loaded = false
}

image_create_texture :: proc() -> bool {
        if state.image_pixels == nil {
                return false
        }

        if state.image_texture != nil {
                sdl.DestroyTexture(state.image_texture)
                state.image_texture = nil
        }

        state.image_texture = sdl.CreateTexture(
                state.renderer,
                .RGBA32,
                .STATIC,
                state.image_width,
                state.image_height,
        )

        if state.image_texture == nil {
                return false
        }

        if !sdl.UpdateTexture(
                state.image_texture,
                nil,
                raw_data(state.image_pixels),
                state.image_width * 4,
        ) {
                sdl.DestroyTexture(state.image_texture)
                state.image_texture = nil
                return false
        }

        return true
}

image_draw :: proc() {
        if !state.image_loaded {
                return
        }

        destination := sdl.FRect{
                state.image_rect.x,
                state.image_rect.y,
                state.image_rect.width,
                state.image_rect.height,
        }

        sdl.RenderTexture(state.renderer, state.image_texture, nil, &destination)
}

image_crop :: proc(x, y, width, height: i32) -> []u8 {
        if width <= 0 || height <= 0 {
                return nil
        }

        pixels := make([]u8, int(width * height * 4))

        for row in 0..<height {
                source_start := int(((y + row) * state.image_width + x) * 4)
                destination_start := int(row * width * 4)
                row_size := int(width * 4)

                copy(
                        pixels[destination_start:destination_start + row_size],
                        state.image_pixels[source_start:source_start + row_size],
                )
        }

        return pixels
}

image_write_png :: proc(path: cstring, pixels: []u8, width, height: i32) -> bool {
        if pixels == nil || width <= 0 || height <= 0 {
                return false
        }

        return stb.write_png(path, width, height, 4, raw_data(pixels), width * 4) != 0
}

// --------------------------------------------------------------------------------------------------------------------
// SELECTION
// --------------------------------------------------------------------------------------------------------------------

selection_draw :: proc() {
        if !state.selection_active {
                return
        }

        rect := sdl.FRect{
                state.selection_rect.x,
                state.selection_rect.y,
                state.selection_rect.width,
                state.selection_rect.height,
        }

        sdl.SetRenderDrawColor(state.renderer, 255, 0, 255, 255)
        sdl.RenderRect(state.renderer, &rect)
}

selection_update :: proc() {
        if !state.image_loaded {
                return
        }

        if state.mouse_left_pressed && rect_contains_point(state.image_rect, state.mouse_position) {
                state.selection_active = true
                state.selection_start  = state.mouse_position
                state.selection_rect   = rect_from_points(state.selection_start, state.mouse_position)
        }

        if state.selection_active && state.mouse_left_down {
                mouse_position := rect_clamp_point(state.image_rect, state.mouse_position)
                state.selection_rect = rect_from_points(state.selection_start, mouse_position)
        }
}

selection_to_image_rect :: proc() -> Rect {
        source := state.image_rect

        destination := Rect{
                0,
                0,
                f32(state.image_width),
                f32(state.image_height),
        }

        a := rect_remap_point(source, destination, Vec2{
                state.selection_rect.x,
                state.selection_rect.y,
        })

        b := rect_remap_point(source, destination, Vec2{
                state.selection_rect.x + state.selection_rect.width,
                state.selection_rect.y + state.selection_rect.height,
        })

        return rect_from_points(a, b)
}

// --------------------------------------------------------------------------------------------------------------------
// OCR
// --------------------------------------------------------------------------------------------------------------------

ocr_run :: proc(path: string) -> string {
        process_state, stdout, stderr, err := os.process_exec(
                os.Process_Desc{
                        command = []string{
                                "tesseract",
                                path,
                                "stdout",
                        },
                },
                context.allocator,
        )

        defer delete(stdout)
        defer delete(stderr)

        if err != nil {
                fmt.println("Tesseract error:", err)
                return ""
        }

        if len(stderr) > 0 {
                fmt.println(string(stderr))
        }

        if !process_state.success || process_state.exit_code != 0 {
                fmt.println("Tesseract exited with:", process_state.exit_code)
                return ""
        }

        return strings.clone(string(stdout))
}


// --------------------------------------------------------------------------------------------------------------------
// RUNTIME
// --------------------------------------------------------------------------------------------------------------------

main :: proc() {
        if !window_initialise("CCTV OCR", 1280, 720) {
                return
        }

        defer delete(state.ocr_text)
        defer image_unload()
        defer window_shutdown()


        for state.running {
                window_poll_events()

                if state.image_loaded {
                        bounds := Rect{
                                0,
                                0,
                                f32(state.window_width),
                                f32(state.window_height),
                        }

                        state.image_rect = rect_fit_inside(f32(state.image_width), f32(state.image_height), bounds)

                        selection_update()
                }

                if state.selection_active && state.mouse_left_released {
                        image_rect := selection_to_image_rect()
                        x, y, width, height := rect_to_pixel_bounds(image_rect)

                        pixels := image_crop(x, y, width, height)

                        if image_write_png("crop.png", pixels, width, height) {
                                delete(state.ocr_text)
                                state.ocr_text = ocr_run("crop.png")

                                if len(state.ocr_text) > 0 {
                                        clipboard_text := strings.clone_to_cstring(state.ocr_text, context.temp_allocator)
                                        sdl.SetClipboardText(clipboard_text)

                                        fmt.println("Copied to clipboard:")
                                        fmt.println(state.ocr_text)
                                }
                        }

                        delete(pixels)

                        state.selection_active = false
                }

                sdl.SetRenderDrawColor(state.renderer, 32, 32, 32, 255)
                sdl.RenderClear(state.renderer)

                if state.image_loaded {
                        image_draw()
                } else {
                			window_draw_drop_message()
                }

                selection_draw()

                sdl.RenderPresent(state.renderer)
        }
}
