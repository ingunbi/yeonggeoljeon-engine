// SPDX-License-Identifier: GPL-3.0-only
// JNI layer between the Java app and the Swift engine's C entry points.
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern int32_t yg_create(const char *data, const char *saves);
extern void yg_tick(void);
extern void yg_cell_long_press(int32_t x, int32_t y);
extern int32_t yg_combat_live(void);
extern void yg_tick_combat(void);
extern void yg_set_active(int32_t value);
extern int32_t yg_revision(void);
extern char *yg_state(void);
extern void yg_free(char *pointer);
extern uint8_t *yg_field_image(int32_t *width, int32_t *height);
extern uint8_t *yg_image(const char *key, int32_t *width, int32_t *height);
extern uint8_t *yg_battle_image(int32_t *width, int32_t *height);
extern void yg_perform(int32_t scope, const char *id);
extern void yg_field_tap(double x, double y);
extern void yg_field_scroll(int32_t dx, int32_t dy);
extern void yg_cell_tap(int32_t x, int32_t y);
extern void yg_advance_dialogue(void);
extern void yg_toggle_skip(void);
extern void yg_toggle_auto(void);
extern void yg_cycle_speed(void);
extern void yg_show_menu(void);
extern void yg_close_menu(void);
extern void yg_show_unit(void);
extern void yg_skip_combat(void);
extern void yg_end_combat(void);
extern void yg_dismiss_banner(void);
extern void yg_clear_error(void);
extern void yg_audio_pull(float *out, int32_t count);
extern int32_t yg_audio_rate(void);

#define NATIVE(name) Java_org_yeonggeoljeon_engine_android_Native_##name

JNIEXPORT void JNICALL NATIVE(setHome)(JNIEnv *env, jclass cls, jstring path) {
    const char *text = (*env)->GetStringUTFChars(env, path, NULL);
    setenv("HOME", text, 1);
    (*env)->ReleaseStringUTFChars(env, path, text);
}
JNIEXPORT jint JNICALL NATIVE(create)(JNIEnv *env, jclass cls, jstring data, jstring saves) {
    const char *d = (*env)->GetStringUTFChars(env, data, NULL);
    const char *s = (*env)->GetStringUTFChars(env, saves, NULL);
    int32_t result = yg_create(d, s);
    (*env)->ReleaseStringUTFChars(env, data, d);
    (*env)->ReleaseStringUTFChars(env, saves, s);
    return result;
}
JNIEXPORT void JNICALL NATIVE(tick)(JNIEnv *env, jclass cls) { yg_tick(); }
JNIEXPORT jboolean JNICALL NATIVE(combatLive)(JNIEnv *env, jclass cls) { return yg_combat_live() != 0; }
JNIEXPORT void JNICALL NATIVE(tickCombat)(JNIEnv *env, jclass cls) { yg_tick_combat(); }
JNIEXPORT void JNICALL NATIVE(setActive)(JNIEnv *env, jclass cls, jboolean value) { yg_set_active(value ? 1 : 0); }
JNIEXPORT jint JNICALL NATIVE(revision)(JNIEnv *env, jclass cls) { return yg_revision(); }
JNIEXPORT jstring JNICALL NATIVE(state)(JNIEnv *env, jclass cls) {
    char *json = yg_state();
    jstring result = (*env)->NewStringUTF(env, json ? json : "{}");
    if (json) yg_free(json);
    return result;
}
static jobject wrap(JNIEnv *env, uint8_t *pixels, int32_t w, int32_t h, jintArray size) {
    if (!pixels) return NULL;
    jint dims[2] = {w, h};
    (*env)->SetIntArrayRegion(env, size, 0, 2, dims);
    return (*env)->NewDirectByteBuffer(env, pixels, (jlong)w * h * 4);
}
JNIEXPORT jobject JNICALL NATIVE(fieldImage)(JNIEnv *env, jclass cls, jintArray size) {
    int32_t w = 0, h = 0;
    uint8_t *p = yg_field_image(&w, &h);
    return wrap(env, p, w, h, size);
}
JNIEXPORT jobject JNICALL NATIVE(image)(JNIEnv *env, jclass cls, jstring key, jintArray size) {
    const char *k = (*env)->GetStringUTFChars(env, key, NULL);
    int32_t w = 0, h = 0;
    uint8_t *p = yg_image(k, &w, &h);
    (*env)->ReleaseStringUTFChars(env, key, k);
    return wrap(env, p, w, h, size);
}
JNIEXPORT jobject JNICALL NATIVE(battleImage)(JNIEnv *env, jclass cls, jintArray size) {
    int32_t w = 0, h = 0;
    uint8_t *p = yg_battle_image(&w, &h);
    return wrap(env, p, w, h, size);
}
JNIEXPORT void JNICALL NATIVE(perform)(JNIEnv *env, jclass cls, jint scope, jstring id) {
    const char *text = (*env)->GetStringUTFChars(env, id, NULL);
    yg_perform(scope, text);
    (*env)->ReleaseStringUTFChars(env, id, text);
}
JNIEXPORT void JNICALL NATIVE(fieldTap)(JNIEnv *env, jclass cls, jdouble x, jdouble y) { yg_field_tap(x, y); }
JNIEXPORT void JNICALL NATIVE(fieldScroll)(JNIEnv *env, jclass cls, jint dx, jint dy) { yg_field_scroll(dx, dy); }
JNIEXPORT void JNICALL NATIVE(cellTap)(JNIEnv *env, jclass cls, jint x, jint y) { yg_cell_tap(x, y); }
JNIEXPORT void JNICALL NATIVE(cellLongPress)(JNIEnv *env, jclass cls, jint x, jint y) { yg_cell_long_press(x, y); }
JNIEXPORT void JNICALL NATIVE(command)(JNIEnv *env, jclass cls, jint code) {
    switch (code) {
    case 0: yg_advance_dialogue(); break;
    case 1: yg_toggle_skip(); break;
    case 2: yg_toggle_auto(); break;
    case 3: yg_cycle_speed(); break;
    case 4: yg_show_menu(); break;
    case 5: yg_close_menu(); break;
    case 6: yg_show_unit(); break;
    case 7: yg_skip_combat(); break;
    case 8: yg_end_combat(); break;
    case 9: yg_dismiss_banner(); break;
    case 10: yg_clear_error(); break;
    default: break;
    }
}
JNIEXPORT void JNICALL NATIVE(audioPull)(JNIEnv *env, jclass cls, jfloatArray out, jint count) {
    jfloat *buffer = (*env)->GetFloatArrayElements(env, out, NULL);
    yg_audio_pull(buffer, count);
    (*env)->ReleaseFloatArrayElements(env, out, buffer, 0);
}
JNIEXPORT jint JNICALL NATIVE(audioRate)(JNIEnv *env, jclass cls) { return yg_audio_rate(); }
