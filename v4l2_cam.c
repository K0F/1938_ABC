#include "v4l2_cam.h"

#ifndef HAVE_V4L2
#define HAVE_V4L2 1
#endif

#if HAVE_V4L2

#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <csetjmp>
#include <vector>
#include <jpeglib.h>

namespace {

int g_fd = -1;
unsigned g_pixfmt = 0;          // V4L2_PIX_FMT_MJPEG nebo V4L2_PIX_FMT_YUYV
int g_w = 0, g_h = 0;
std::vector<unsigned char> g_rgb;   // dekódovaný R8G8B8 výstup

struct Buf { void* start; size_t length; };
Buf g_bufs[8];
unsigned g_nbufs = 0;

int xioctl(int fd, unsigned long req, void* arg) {
    int r;
    do { r = ioctl(fd, req, arg); } while (r == -1 && errno == EINTR);
    return r;
}

void unmap_bufs() {
    for (unsigned i = 0; i < g_nbufs; i++)
        if (g_bufs[i].start) munmap(g_bufs[i].start, g_bufs[i].length);
    g_nbufs = 0;
}

// ── libjpeg: dekódování MJPEG do g_rgb (R8G8B8) ──────────────────────
// Vlastní error handler se setjmp, ať vadný JPEG neshodí celý tracker
// (default libjpeg error_exit volá exit()).
struct JpegErr {
    struct jpeg_error_mgr pub;
    jmp_buf jump;
};
void jpeg_error_exit(j_common_ptr cinfo) {
    JpegErr* e = reinterpret_cast<JpegErr*>(cinfo->err);
    longjmp(e->jump, 1);
}
void jpeg_output_message(j_common_ptr) {}   // potlač varování na stderr

bool decode_mjpg(const unsigned char* data, size_t len) {
    struct jpeg_decompress_struct cinfo;
    JpegErr jerr;
    cinfo.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = jpeg_error_exit;
    jerr.pub.output_message = jpeg_output_message;
    if (setjmp(jerr.jump)) {
        jpeg_destroy_decompress(&cinfo);
        return false;
    }
    jpeg_create_decompress(&cinfo);
    jpeg_mem_src(&cinfo, data, len);
    if (jpeg_read_header(&cinfo, TRUE) != JPEG_HEADER_OK) {
        jpeg_destroy_decompress(&cinfo);
        return false;
    }
    cinfo.out_color_space = JCS_RGB;
    jpeg_start_decompress(&cinfo);
    int w = (int)cinfo.output_width, h = (int)cinfo.output_height;
    if (w <= 0 || h <= 0 || cinfo.output_components != 3) {
        jpeg_destroy_decompress(&cinfo);
        return false;
    }
    if (g_w != w || g_h != h || (int)g_rgb.size() != w * h * 3) {
        g_w = w; g_h = h;
        g_rgb.resize((size_t)w * h * 3);
    }
    while (cinfo.output_scanline < cinfo.output_height) {
        JSAMPROW row = &g_rgb[(size_t)cinfo.output_scanline * w * 3];
        jpeg_read_scanlines(&cinfo, &row, 1);
    }
    jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);
    return true;
}

// ── YUYV 4:2:2 -> R8G8B8 ─────────────────────────────────────────────
inline unsigned char clamp8(int v) {
    return (unsigned char)(v < 0 ? 0 : (v > 255 ? 255 : v));
}
bool convert_yuyv(const unsigned char* data, int w, int h, size_t len) {
    size_t need = (size_t)w * h * 2;
    if (len < need) return false;
    if (g_w != w || g_h != h || (int)g_rgb.size() != w * h * 3) {
        g_w = w; g_h = h;
        g_rgb.resize((size_t)w * h * 3);
    }
    for (int y = 0; y < h; y++) {
        const unsigned char* src = data + (size_t)y * w * 2;
        unsigned char* dst = &g_rgb[(size_t)y * w * 3];
        for (int x = 0; x < w; x += 2) {
            int y0 = src[0], u = src[1] - 128, y1 = src[2], v = src[3] - 128;
            src += 4;
            int r = (298 * (y0) + 409 * v + 128) >> 8;
            int g = (298 * (y0) - 100 * u - 208 * v + 128) >> 8;
            int b = (298 * (y0) + 516 * u + 128) >> 8;
            dst[0] = clamp8(r); dst[1] = clamp8(g); dst[2] = clamp8(b);
            r = (298 * (y1) + 409 * v + 128) >> 8;
            g = (298 * (y1) - 100 * u - 208 * v + 128) >> 8;
            b = (298 * (y1) + 516 * u + 128) >> 8;
            dst[3] = clamp8(r); dst[4] = clamp8(g); dst[5] = clamp8(b);
            dst += 6;
        }
    }
    return true;
}

} // namespace

extern "C" int v4l2_open(const char* dev, int req_w, int req_h, int want_mjpg) {
    v4l2_close();
    g_fd = open(dev, O_RDWR | O_NONBLOCK);
    if (g_fd < 0) return -1;

    struct v4l2_format fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = req_w;
    fmt.fmt.pix.height = req_h;
    fmt.fmt.pix.pixelformat = want_mjpg ? V4L2_PIX_FMT_MJPEG : V4L2_PIX_FMT_YUYV;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    if (xioctl(g_fd, VIDIOC_S_FMT, &fmt) < 0) { v4l2_close(); return -2; }

    // Když driver neumí MJPEG, zkus ještě YUYV (a naopak necháme, co řekl).
    if (want_mjpg && fmt.fmt.pix.pixelformat != V4L2_PIX_FMT_MJPEG) {
        memset(&fmt, 0, sizeof(fmt));
        fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        fmt.fmt.pix.width = req_w;
        fmt.fmt.pix.height = req_h;
        fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
        fmt.fmt.pix.field = V4L2_FIELD_NONE;
        if (xioctl(g_fd, VIDIOC_S_FMT, &fmt) < 0) { v4l2_close(); return -2; }
    }
    g_w = fmt.fmt.pix.width;
    g_h = fmt.fmt.pix.height;
    g_pixfmt = fmt.fmt.pix.pixelformat;
    if (g_pixfmt != V4L2_PIX_FMT_MJPEG && g_pixfmt != V4L2_PIX_FMT_YUYV) {
        v4l2_close();
        return -3;
    }

    struct v4l2_requestbuffers req;
    memset(&req, 0, sizeof(req));
    req.count = 4;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(g_fd, VIDIOC_REQBUFS, &req) < 0 || req.count < 2) {
        v4l2_close();
        return -4;
    }
    for (g_nbufs = 0; g_nbufs < req.count && g_nbufs < 8; g_nbufs++) {
        struct v4l2_buffer b;
        memset(&b, 0, sizeof(b));
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.memory = V4L2_MEMORY_MMAP;
        b.index = g_nbufs;
        if (xioctl(g_fd, VIDIOC_QUERYBUF, &b) < 0) { v4l2_close(); return -5; }
        g_bufs[g_nbufs].length = b.length;
        g_bufs[g_nbufs].start = mmap(NULL, b.length, PROT_READ | PROT_WRITE,
                                     MAP_SHARED, g_fd, b.m.offset);
        if (g_bufs[g_nbufs].start == MAP_FAILED) {
            g_bufs[g_nbufs].start = NULL;
            v4l2_close();
            return -6;
        }
    }
    for (unsigned i = 0; i < g_nbufs; i++) {
        struct v4l2_buffer b;
        memset(&b, 0, sizeof(b));
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.memory = V4L2_MEMORY_MMAP;
        b.index = i;
        if (xioctl(g_fd, VIDIOC_QBUF, &b) < 0) { v4l2_close(); return -7; }
    }
    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(g_fd, VIDIOC_STREAMON, &type) < 0) { v4l2_close(); return -8; }
    return 0;
}

extern "C" void v4l2_lock_exposure(int on) {
    if (g_fd < 0) return;
    struct v4l2_control c;
    // V4L2_EXPOSURE_MANUAL=1; hodnoty zůstávají na kameře, jen je zamkneme.
    c.id = V4L2_CID_EXPOSURE_AUTO;
    c.value = on ? V4L2_EXPOSURE_MANUAL : V4L2_EXPOSURE_APERTURE_PRIORITY;
    xioctl(g_fd, VIDIOC_S_CTRL, &c);
    c.id = V4L2_CID_AUTO_WHITE_BALANCE;
    c.value = on ? 0 : 1;
    xioctl(g_fd, VIDIOC_S_CTRL, &c);
}

extern "C" int v4l2_grab(struct v4l2_frame* out, int timeout_ms) {
    if (g_fd < 0 || !out) return -1;
    fd_set fds;
    FD_ZERO(&fds);
    FD_SET(g_fd, &fds);
    struct timeval tv;
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    int r = select(g_fd + 1, &fds, NULL, NULL, &tv);
    if (r <= 0) return -1;   // timeout nebo chyba selectu

    struct v4l2_buffer b;
    memset(&b, 0, sizeof(b));
    b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    b.memory = V4L2_MEMORY_MMAP;
    if (xioctl(g_fd, VIDIOC_DQBUF, &b) < 0) return -1;
    if (b.index >= g_nbufs) { xioctl(g_fd, VIDIOC_QBUF, &b); return -1; }

    bool ok = false;
    if (g_pixfmt == V4L2_PIX_FMT_MJPEG)
        ok = decode_mjpg((const unsigned char*)g_bufs[b.index].start, b.bytesused);
    else
        ok = convert_yuyv((const unsigned char*)g_bufs[b.index].start,
                          g_w, g_h, b.bytesused);

    xioctl(g_fd, VIDIOC_QBUF, &b);
    if (!ok) return -1;
    out->w = g_w; out->h = g_h; out->rgb = g_rgb.data();
    return 0;
}

extern "C" int v4l2_width(void) { return g_w; }
extern "C" int v4l2_height(void) { return g_h; }

extern "C" void v4l2_close(void) {
    if (g_fd >= 0) {
        enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        xioctl(g_fd, VIDIOC_STREAMOFF, &type);
    }
    unmap_bufs();
    if (g_fd >= 0) { close(g_fd); g_fd = -1; }
    g_w = g_h = 0;
    g_pixfmt = 0;
}

#else  // !HAVE_V4L2 — bez V4L2 (Termux/Android): stuby

extern "C" int v4l2_open(const char*, int, int, int) { return -1; }
extern "C" void v4l2_lock_exposure(int) {}
extern "C" int v4l2_grab(struct v4l2_frame*, int) { return -1; }
extern "C" int v4l2_width(void) { return 0; }
extern "C" int v4l2_height(void) { return 0; }
extern "C" void v4l2_close(void) {}

#endif
