#define _DEFAULT_SOURCE
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <X11/XKBlib.h>
#include <X11/Xft/Xft.h>
#include <X11/extensions/Xrandr.h>
#include <security/pam_appl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pwd.h>
#include <time.h>
#include <sys/select.h>

#define MAX_PASS     256
#define BLUR_RADIUS  20     /* full-screen background blur */
#define BLUR_PASSES  3
#define BOX_W        380
#define BOX_H        52
#define BOX_R        18     /* password box corner radius */
#define DOT_R        6
#define ABOVE_BOX    46     /* pixel budget above box (username)    */
#define BELOW_BOX    46     /* pixel budget below box (error text)  */

/* ── pywal colors ────────────────────────────────────────────────────────── */
typedef struct { uint16_t r, g, b; } WalColor;

static WalColor g_wal[16] = {
    { 0x0f00, 0x0f00, 0x1e00 }, /* 0  background        */
    { 0xef00, 0x4400, 0x4400 }, /* 1  red / error       */
    { 0x4400, 0xaa00, 0x5500 }, /* 2  green             */
    { 0xee00, 0xbb00, 0x4400 }, /* 3  yellow            */
    { 0x4400, 0x9900, 0xdd00 }, /* 4  blue (border)     */
    { 0xbb00, 0x4400, 0xbb00 }, /* 5  magenta           */
    { 0x4400, 0xbb00, 0xcc00 }, /* 6  cyan              */
    { 0xcc00, 0xcc00, 0xcc00 }, /* 7  light gray        */
    { 0x5000, 0x5000, 0x6000 }, /* 8  dim (placeholder) */
    { 0xff00, 0x6600, 0x6600 }, /* 9  bright red        */
    { 0x6600, 0xdd00, 0x7700 }, /* 10 bright green      */
    { 0xff00, 0xdd00, 0x6600 }, /* 11 bright yellow     */
    { 0x6600, 0xaa00, 0xff00 }, /* 12 bright blue       */
    { 0xdd00, 0x6600, 0xdd00 }, /* 13 bright magenta    */
    { 0x6600, 0xdd00, 0xff00 }, /* 14 bright cyan       */
    { 0xff00, 0xff00, 0xff00 }, /* 15 foreground/white  */
};

static void load_wal_colors(void)
{
    const char *home = getenv("HOME");
    if (!home) return;
    char path[512];
    snprintf(path, sizeof path, "%s/.cache/wal/colors", home);
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[32];
    int  n = 0;
    while (n < 16 && fgets(line, sizeof line, f)) {
        unsigned int r, g, b;
        if (sscanf(line, "#%02x%02x%02x", &r, &g, &b) == 3) {
            g_wal[n].r = (uint16_t)(r * 257);
            g_wal[n].g = (uint16_t)(g * 257);
            g_wal[n].b = (uint16_t)(b * 257);
            n++;
        }
    }
    fclose(f);
}

static unsigned long wal_pixel(int idx, float br)
{
    uint8_t r = (uint8_t)((g_wal[idx].r >> 8) * br);
    uint8_t g = (uint8_t)((g_wal[idx].g >> 8) * br);
    uint8_t b = (uint8_t)((g_wal[idx].b >> 8) * br);
    return ((unsigned long)r << 16) | ((unsigned long)g << 8) | b;
}

static void xft_wal(Display *dpy, int scr, XftColor *c, int idx, uint16_t alpha)
{
    XRenderColor xrc = { g_wal[idx].r, g_wal[idx].g, g_wal[idx].b, alpha };
    XftColorAllocValue(dpy, DefaultVisual(dpy, scr),
                       DefaultColormap(dpy, scr), &xrc, c);
}

/* ── pam ────────────────────────────────────────────────────────────────── */
static char g_pass[MAX_PASS + 1];
static int  g_plen   = 0;
static int  g_failed = 0;

static int pam_cb(int n, const struct pam_message **msg,
                  struct pam_response **resp, void *data)
{
    *resp = calloc(n, sizeof **resp);
    if (!*resp) return PAM_CONV_ERR;
    for (int i = 0; i < n; i++)
        if (msg[i]->msg_style == PAM_PROMPT_ECHO_OFF ||
            msg[i]->msg_style == PAM_PROMPT_ECHO_ON)
            (*resp)[i].resp = strdup((char *)data);
    return PAM_SUCCESS;
}

static int try_auth(const char *user, const char *pass)
{
    struct pam_conv conv = { pam_cb, (void *)pass };
    pam_handle_t *ph = NULL;
    int r = pam_start("login", user, &conv, &ph);
    if (r != PAM_SUCCESS) return 0;
    r = pam_authenticate(ph, PAM_SILENT);
    pam_end(ph, r);
    return r == PAM_SUCCESS;
}

/* ── blur helpers (separable box blur, called by both bg and frost) ───────── */
static void blur_h(const uint8_t *s, uint8_t *d, int w, int h, int r)
{
    float inv = 1.0f / (2*r + 1);
    for (int y = 0; y < h; y++) {
        const uint8_t *row = s + (size_t)y * w * 3;
        uint8_t       *out = d + (size_t)y * w * 3;
        for (int c = 0; c < 3; c++) {
            int acc = 0;
            for (int k = -r; k <= r; k++)
                acc += row[(k < 0 ? 0 : k >= w ? w-1 : k) * 3 + c];
            for (int x = 0; x < w; x++) {
                out[x*3+c] = (uint8_t)(acc * inv);
                acc += row[(x+r+1 >= w ? w-1 : x+r+1) * 3 + c]
                     - row[(x-r   <  0 ?    0 : x-r  ) * 3 + c];
            }
        }
    }
}

static void blur_v(const uint8_t *s, uint8_t *d, int w, int h, int r)
{
    float inv = 1.0f / (2*r + 1);
    for (int x = 0; x < w; x++) {
        for (int c = 0; c < 3; c++) {
            int acc = 0;
            for (int k = -r; k <= r; k++)
                acc += s[((size_t)(k < 0 ? 0 : k >= h ? h-1 : k) * w + x) * 3 + c];
            for (int y = 0; y < h; y++) {
                d[((size_t)y * w + x) * 3 + c] = (uint8_t)(acc * inv);
                acc += s[((size_t)(y+r+1 >= h ? h-1 : y+r+1) * w + x) * 3 + c]
                     - s[((size_t)(y-r   <  0 ?    0 : y-r  ) * w + x) * 3 + c];
            }
        }
    }
}

/* ── full-screen background blur ─────────────────────────────────────────── */
static Pixmap make_blur_pm(Display *dpy, int scr, int w, int h)
{
    XImage *cap = XGetImage(dpy, RootWindow(dpy, scr), 0, 0, w, h,
                            AllPlanes, ZPixmap);
    if (!cap) { fputs("XGetImage failed\n", stderr); exit(1); }

    size_t  npx = (size_t)w * h;
    uint8_t *px  = malloc(npx * 3);
    uint8_t *tmp = malloc(npx * 3);
    if (!px || !tmp) { perror("malloc"); exit(1); }

    {
        int rs = __builtin_ctz(cap->red_mask);
        int gs = __builtin_ctz(cap->green_mask);
        int bs = __builtin_ctz(cap->blue_mask);
        for (int y = 0; y < h; y++) {
            uint8_t *out = px + (size_t)y * w * 3;
            if (cap->bits_per_pixel == 32) {
                uint32_t *row = (void *)(cap->data
                                + (size_t)y * cap->bytes_per_line);
                for (int x = 0; x < w; x++) {
                    out[x*3]   = (row[x] >> rs) & 0xFF;
                    out[x*3+1] = (row[x] >> gs) & 0xFF;
                    out[x*3+2] = (row[x] >> bs) & 0xFF;
                }
            } else {
                for (int x = 0; x < w; x++) {
                    unsigned long p = XGetPixel(cap, x, y);
                    out[x*3]   = (p & cap->red_mask)   >> rs;
                    out[x*3+1] = (p & cap->green_mask) >> gs;
                    out[x*3+2] = (p & cap->blue_mask)  >> bs;
                }
            }
        }
    }
    XDestroyImage(cap);

    for (int i = 0; i < BLUR_PASSES; i++) {
        blur_h(px, tmp, w, h, BLUR_RADIUS);
        blur_v(tmp, px, w, h, BLUR_RADIUS);
    }
    free(tmp);

    XImage *out = XCreateImage(dpy, DefaultVisual(dpy, scr),
                               DefaultDepth(dpy, scr), ZPixmap,
                               0, NULL, w, h, 32, 0);
    out->data = malloc((size_t)out->bytes_per_line * h);
    {
        int rs = __builtin_ctz(out->red_mask);
        int gs = __builtin_ctz(out->green_mask);
        int bs = __builtin_ctz(out->blue_mask);
        for (int y = 0; y < h; y++) {
            uint32_t *row = (void *)(out->data
                            + (size_t)y * out->bytes_per_line);
            uint8_t  *in  = px + (size_t)y * w * 3;
            for (int x = 0; x < w; x++)
                row[x] = ((uint32_t)in[x*3]   << rs)
                        | ((uint32_t)in[x*3+1] << gs)
                        | ((uint32_t)in[x*3+2] << bs);
        }
    }
    free(px);

    Pixmap pm = XCreatePixmap(dpy, RootWindow(dpy, scr), w, h,
                              DefaultDepth(dpy, scr));
    GC pgc = XCreateGC(dpy, pm, 0, NULL);
    XPutImage(dpy, pm, pgc, out, 0, 0, 0, 0, w, h);
    XFreeGC(dpy, pgc);
    XDestroyImage(out);
    return pm;
}


/* ── monitor detection ───────────────────────────────────────────────────── */
typedef struct { int x, y, w, h; } Monitor;

static Monitor get_primary_monitor(Display *dpy, int scr)
{
    Monitor m = { 0, 0, DisplayWidth(dpy, scr), DisplayHeight(dpy, scr) };
    int nmon = 0;
    XRRMonitorInfo *mons = XRRGetMonitors(dpy, RootWindow(dpy, scr), True, &nmon);
    if (!mons) return m;
    for (int i = 0; i < nmon; i++) {
        if (mons[i].primary) {
            m.x = mons[i].x; m.y = mons[i].y;
            m.w = mons[i].width; m.h = mons[i].height;
            break;
        }
    }
    XRRFreeMonitors(mons);
    return m;
}

/* ── rounded rectangle primitives ───────────────────────────────────────── */

/* draw the border of a rounded rectangle (arcs + straight edges) */
static void draw_rrect(Display *dpy, Drawable d, GC gc,
                       int x, int y, int w, int h, int r)
{
    XDrawArc(dpy, d, gc, x,       y,       2*r, 2*r, 90*64,  90*64);
    XDrawArc(dpy, d, gc, x+w-2*r, y,       2*r, 2*r, 0,      90*64);
    XDrawArc(dpy, d, gc, x,       y+h-2*r, 2*r, 2*r, 180*64, 90*64);
    XDrawArc(dpy, d, gc, x+w-2*r, y+h-2*r, 2*r, 2*r, 270*64, 90*64);
    XDrawLine(dpy, d, gc, x+r,   y,   x+w-r, y);
    XDrawLine(dpy, d, gc, x+r,   y+h, x+w-r, y+h);
    XDrawLine(dpy, d, gc, x,   y+r, x,   y+h-r);
    XDrawLine(dpy, d, gc, x+w, y+r, x+w, y+h-r);
}

/* ── drawing ─────────────────────────────────────────────────────────────── */
static void draw_frame(Display *dpy, Window win, Pixmap bg, GC gc,
                       int scr, int sw, int sh, Monitor mon,
                       XftFont *fp, XftFont *fu, XftFont *fc, XftFont *fd,
                       const char *uname)
{
    Visual  *vis  = DefaultVisual(dpy, scr);
    Colormap cmap = DefaultColormap(dpy, scr);

    XCopyArea(dpy, bg, win, gc, 0, 0, sw, sh, 0, 0);

    int cluster_h = ABOVE_BOX + BOX_H + BELOW_BOX;
    int bx = mon.x + (mon.w - BOX_W) / 2;
    int by = mon.y + mon.h / 2 - cluster_h / 2 + ABOVE_BOX;

    /* clock — centered in the upper quarter of the primary monitor */
    {
        time_t     now = time(NULL);
        struct tm *tm  = localtime(&now);
        char timebuf[8], datebuf[32];
        strftime(timebuf, sizeof timebuf, "%H:%M", tm);
        strftime(datebuf, sizeof datebuf, "%A, %B %d", tm);

        XftDraw *xd = XftDrawCreate(dpy, win, vis, cmap);
        XftColor col;
        xft_wal(dpy, scr, &col, 15, 0xFFFF);

        XGlyphInfo ext;
        int cx = mon.x + mon.w / 2;
        int cy = mon.y + mon.h / 4;

        XftTextExtentsUtf8(dpy, fc, (FcChar8 *)timebuf, strlen(timebuf), &ext);
        XftDrawStringUtf8(xd, &col, fc,
                          cx - ext.xOff / 2, cy,
                          (FcChar8 *)timebuf, strlen(timebuf));

        XftTextExtentsUtf8(dpy, fd, (FcChar8 *)datebuf, strlen(datebuf), &ext);
        XftDrawStringUtf8(xd, &col, fd,
                          cx - ext.xOff / 2,
                          cy + fc->descent + fd->ascent + 6,
                          (FcChar8 *)datebuf, strlen(datebuf));

        XftColorFree(dpy, vis, cmap, &col);
        XftDrawDestroy(xd);
    }

    /* username above the box */
    {
        XftDraw *xd = XftDrawCreate(dpy, win, vis, cmap);
        XftColor col;
        xft_wal(dpy, scr, &col, 15, 0xFFFF);
        XGlyphInfo ext;
        XftTextExtentsUtf8(dpy, fu, (FcChar8 *)uname, strlen(uname), &ext);
        XftDrawStringUtf8(xd, &col, fu,
                          bx + (BOX_W - ext.xOff) / 2,
                          by - 14,
                          (FcChar8 *)uname, strlen(uname));
        XftColorFree(dpy, vis, cmap, &col);
        XftDrawDestroy(xd);
    }

    /* flash a red border only on wrong password */
    if (g_failed) {
        XSetForeground(dpy, gc, wal_pixel(1, 1.0f));
        draw_rrect(dpy, win, gc, bx, by, BOX_W, BOX_H, BOX_R);
    }

    /* password dots or placeholder hint */
    {
        int max_d = (BOX_W - 24) / (DOT_R*2 + 8);
        int nd    = g_plen < max_d ? g_plen : max_d;
        int cy    = by + BOX_H / 2;

        XSetForeground(dpy, gc, wal_pixel(g_failed ? 1 : 4, 1.0f));
        if (nd > 0) {
            int span = nd * (DOT_R*2 + 8) - 8;
            int x0   = bx + (BOX_W - span) / 2 + DOT_R;
            for (int i = 0; i < nd; i++)
                XFillArc(dpy, win, gc,
                         x0 + i*(DOT_R*2+8) - DOT_R, cy - DOT_R,
                         DOT_R*2, DOT_R*2, 0, 360*64);
        } else if (!g_failed) {
            XftDraw *xd = XftDrawCreate(dpy, win, vis, cmap);
            XftColor col;
            xft_wal(dpy, scr, &col, 8, 0xFFFF);
            const char *hint = "enter password";
            XGlyphInfo  ext;
            XftTextExtentsUtf8(dpy, fp, (FcChar8 *)hint, strlen(hint), &ext);
            XftDrawStringUtf8(xd, &col, fp,
                              bx + (BOX_W - ext.xOff) / 2,
                              cy + (fp->ascent - fp->descent) / 2,
                              (FcChar8 *)hint, strlen(hint));
            XftColorFree(dpy, vis, cmap, &col);
            XftDrawDestroy(xd);
        }
    }

    /* "Wrong password" below the box */
    if (g_failed) {
        XftDraw *xd = XftDrawCreate(dpy, win, vis, cmap);
        XftColor col;
        xft_wal(dpy, scr, &col, 1, 0xFFFF);
        const char *msg = "Wrong password";
        XGlyphInfo  ext;
        XftTextExtentsUtf8(dpy, fu, (FcChar8 *)msg, strlen(msg), &ext);
        XftDrawStringUtf8(xd, &col, fu,
                          bx + (BOX_W - ext.xOff) / 2,
                          by + BOX_H + fu->ascent + 12,
                          (FcChar8 *)msg, strlen(msg));
        XftColorFree(dpy, vis, cmap, &col);
        XftDrawDestroy(xd);
    }

    XFlush(dpy);
}

/* ── main ───────────────────────────────────────────────────────────────── */
int main(void)
{
    load_wal_colors();

    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fputs("cannot open display\n", stderr); return 1; }

    int scr = DefaultScreen(dpy);
    int sw  = DisplayWidth(dpy, scr);
    int sh  = DisplayHeight(dpy, scr);

    struct passwd *pw    = getpwuid(getuid());
    const char    *uname = pw ? pw->pw_name : "user";

    Pixmap  bg  = make_blur_pm(dpy, scr, sw, sh);
    Monitor mon = get_primary_monitor(dpy, scr);


    XSetWindowAttributes swa = {
        .background_pixmap = bg,
        .override_redirect = True,
        .event_mask        = KeyPressMask | ExposureMask,
    };
    Window win = XCreateWindow(dpy, RootWindow(dpy, scr),
                               0, 0, sw, sh, 0,
                               CopyFromParent, InputOutput, CopyFromParent,
                               CWBackPixmap | CWOverrideRedirect | CWEventMask,
                               &swa);
    XStoreName(dpy, win, "lockscreen");
    XMapRaised(dpy, win);
    XFlush(dpy);

    for (int i = 0; i < 1000; i++) {
        if (XGrabKeyboard(dpy, win, True,
                          GrabModeAsync, GrabModeAsync, CurrentTime)
            == GrabSuccess) break;
        usleep(1000);
    }
    XGrabPointer(dpy, win, True,
                 ButtonPressMask | ButtonReleaseMask | PointerMotionMask,
                 GrabModeAsync, GrabModeAsync, win, None, CurrentTime);

    XftFont *fp = XftFontOpenName(dpy, scr, "Sans:size=14");
    XftFont *fu = XftFontOpenName(dpy, scr, "Sans:size=18:bold");
    XftFont *fc = XftFontOpenName(dpy, scr, "Sans:size=42:bold");
    XftFont *fd = XftFontOpenName(dpy, scr, "Sans:size=15");
    if (!fp) fp = XftFontOpenName(dpy, scr, "fixed:size=14");
    if (!fu) fu = XftFontOpenName(dpy, scr, "fixed:size=18");
    if (!fc) fc = XftFontOpenName(dpy, scr, "fixed:size=42");
    if (!fd) fd = XftFontOpenName(dpy, scr, "fixed:size=15");
    if (!fp || !fu || !fc || !fd) { fputs("cannot load fonts\n", stderr); return 1; }

#define DRAW() draw_frame(dpy, win, bg, gc, scr, sw, sh, mon, fp, fu, fc, fd, uname)

    GC gc = XCreateGC(dpy, win, 0, NULL);
    DRAW();

    int xfd = ConnectionNumber(dpy);
    for (;;) {
        /* drain all pending X events */
        while (XPending(dpy)) {
            XEvent ev;
            XNextEvent(dpy, &ev);

            if (ev.type == Expose) {
                if (ev.xexpose.count == 0) DRAW();
                continue;
            }
            if (ev.type != KeyPress) continue;

            g_failed = 0;
            KeySym ks = XkbKeycodeToKeysym(dpy, ev.xkey.keycode, 0, 0);

            if (ks == XK_Return || ks == XK_KP_Enter) {
                if (try_auth(uname, g_pass)) goto done;
                g_failed = 1;
                g_plen = 0;
                explicit_bzero(g_pass, sizeof g_pass);
            } else if (ks == XK_BackSpace) {
                if (g_plen > 0) g_pass[--g_plen] = '\0';
            } else if (ks == XK_Escape) {
                g_plen = 0;
                explicit_bzero(g_pass, sizeof g_pass);
            } else {
                char buf[8] = {0};
                int  len = XLookupString(&ev.xkey, buf, sizeof buf, NULL, NULL);
                if (len > 0 && g_plen + len < MAX_PASS) {
                    memcpy(g_pass + g_plen, buf, len);
                    g_plen += len;
                }
            }
            DRAW();
        }

        /* wait up to 1 second — wake early if an X event arrives */
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(xfd, &fds);
        struct timeval tv = { 1, 0 };
        if (select(xfd + 1, &fds, NULL, NULL, &tv) == 0)
            DRAW(); /* clock tick */
    }
done:;

    XUngrabKeyboard(dpy, CurrentTime);
    XUngrabPointer(dpy, CurrentTime);
    explicit_bzero(g_pass, sizeof g_pass);
    XFreeGC(dpy, gc);
    XftFontClose(dpy, fp);
    XftFontClose(dpy, fu);
    XftFontClose(dpy, fc);
    XftFontClose(dpy, fd);
    XFreePixmap(dpy, bg);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return 0;
}
