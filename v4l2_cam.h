#ifndef V4L2_CAM_H
#define V4L2_CAM_H

// Minimální V4L2 webkamera: MJPEG (dekódované libjpeg-turbo) nebo YUYV,
// mmap streaming. Nahrazuje OpenCV cv::VideoCapture, ať tracker netáhne
// celé OpenCV. Na systémech bez V4L2 (Termux/Android) je HAVE_V4L2=0 a všechny
// funkce jsou stuby (kamera se prostě neotevře, zvuk + RF tlačítka jedou dál).

#ifdef __cplusplus
extern "C" {
#endif

struct v4l2_frame {
    int w, h;                 // skutečné rozměry snímku
    unsigned char* rgb;       // w*h*3, R8G8B8 (raylib PIXELFORMAT_UNCOMPRESSED_R8G8B8)
};

// Otevře zařízení a nastaví formát. want_mjpg=1 zkusí MJPEG (vyšší rozlišení
// po USB2), jinak/při neúspěchu spadne na YUYV. Vrací 0 = ok.
int v4l2_open(const char* dev, int req_w, int req_h, int want_mjpg);
// Zacloní expozici a vyvážení bílé (napevno), ať barvy koulí nedriftují.
void v4l2_lock_exposure(int on);
// Počká na snímek (timeout_ms) a naplní out->rgb (pointer do interního bufferu).
// Vrací 0 = ok, -1 = timeout/selhal/není otevřeno.
int v4l2_grab(struct v4l2_frame* out, int timeout_ms);
int v4l2_width(void);
int v4l2_height(void);
void v4l2_close(void);

#ifdef __cplusplus
}
#endif

#endif
