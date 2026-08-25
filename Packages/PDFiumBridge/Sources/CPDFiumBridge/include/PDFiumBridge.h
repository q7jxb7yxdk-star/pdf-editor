#ifndef PDFIUM_BRIDGE_H
#define PDFIUM_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PEPDFDocument* PEPDFDocumentRef;
typedef struct PEPDFFont* PEPDFFontRef;

typedef enum PEPDFObjectType {
    PEPDFObjectTypeUnknown = 0,
    PEPDFObjectTypeText = 1,
    PEPDFObjectTypePath = 2,
    PEPDFObjectTypeImage = 3,
    PEPDFObjectTypeShading = 4,
    PEPDFObjectTypeForm = 5,
} PEPDFObjectType;

typedef struct PEPDFObjectInfo {
    int32_t type;
    float left;
    float bottom;
    float right;
    float top;
    float matrixA;
    float matrixB;
    float matrixC;
    float matrixD;
    float matrixE;
    float matrixF;
    uint32_t fillRed;
    uint32_t fillGreen;
    uint32_t fillBlue;
    uint32_t fillAlpha;
    float fontSize;
    uint32_t imagePixelWidth;
    uint32_t imagePixelHeight;
} PEPDFObjectInfo;

typedef struct PEPDFPageInfo {
    float width;
    float height;
    int32_t rotation;
} PEPDFPageInfo;

void PEPDFLibraryInitialize(void);
void PEPDFLibraryDestroy(void);

PEPDFDocumentRef PEPDFDocumentCreate(
    const uint8_t* bytes,
    size_t length,
    const char* password,
    uint32_t* errorCode
);
void PEPDFDocumentClose(PEPDFDocumentRef document);

int32_t PEPDFDocumentPageCount(PEPDFDocumentRef document);
bool PEPDFDocumentIsEncrypted(PEPDFDocumentRef document);
uint32_t PEPDFDocumentPermissions(PEPDFDocumentRef document);
int32_t PEPDFDocumentSignatureCount(PEPDFDocumentRef document);

bool PEPDFPageInfoAtIndex(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    PEPDFPageInfo* outputInfo
);
bool PEPDFDocumentInsertBlankPage(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    double width,
    double height
);
bool PEPDFDocumentDeletePage(
    PEPDFDocumentRef document,
    int32_t pageIndex
);
bool PEPDFDocumentSetPageRotation(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t quarterTurnsClockwise
);
bool PEPDFDocumentMovePages(
    PEPDFDocumentRef document,
    const int32_t* pageIndices,
    size_t pageIndicesLength,
    int32_t destinationIndex
);
bool PEPDFDocumentImportPages(
    PEPDFDocumentRef document,
    const uint8_t* sourceBytes,
    size_t sourceLength,
    const char* password,
    int32_t destinationIndex,
    uint32_t* errorCode
);
bool PEPDFDocumentCopyPages(
    PEPDFDocumentRef document,
    const int32_t* pageIndices,
    size_t pageIndicesLength,
    uint8_t** outputBytes,
    size_t* outputLength
);

bool PEPDFDocumentCopyData(
    PEPDFDocumentRef document,
    bool removeSecurity,
    uint8_t** outputBytes,
    size_t* outputLength
);

bool PEPDFAnnotationSetColor(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t annotationIndex,
    uint32_t red,
    uint32_t green,
    uint32_t blue,
    uint32_t alpha
);
bool PEPDFAnnotationGetColor(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t annotationIndex,
    uint32_t* red,
    uint32_t* green,
    uint32_t* blue,
    uint32_t* alpha
);

int32_t PEPDFPageObjectCount(PEPDFDocumentRef document, int32_t pageIndex);
int32_t PEPDFPageObjectCountRecursive(
    PEPDFDocumentRef document,
    int32_t pageIndex
);
bool PEPDFPageObjectCopyPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t flatIndex,
    int32_t** outputIndices,
    size_t* outputLength
);
bool PEPDFPageObjectInfoAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength,
    PEPDFObjectInfo* outputInfo
);
bool PEPDFPageObjectCopyTextAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength,
    uint16_t** outputText,
    size_t* outputLength
);
bool PEPDFPageObjectCopyFontNameAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength,
    char** outputName,
    size_t* outputLength
);
bool PEPDFPageObjectCopyFontDataAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength,
    uint8_t** outputBytes,
    size_t* outputLength
);
bool PEPDFPageObjectInfo(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t objectIndex,
    PEPDFObjectInfo* outputInfo
);
bool PEPDFPageObjectCopyText(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t objectIndex,
    uint16_t** outputText,
    size_t* outputLength
);
bool PEPDFPageObjectCopyFontName(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t objectIndex,
    char** outputName,
    size_t* outputLength
);

bool PEPDFPageObjectReplaceText(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t objectIndex,
    const uint16_t* text,
    size_t textLength
);
bool PEPDFPageObjectTranslate(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t objectIndex,
    float deltaX,
    float deltaY
);
bool PEPDFPageObjectDelete(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t objectIndex
);
bool PEPDFPageObjectReplaceTextAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength,
    const uint16_t* text,
    size_t textLength
);
bool PEPDFDocumentLastMutationRejectedForAppearance(
    PEPDFDocumentRef document
);
bool PEPDFPageObjectTranslateAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength,
    float pageDeltaX,
    float pageDeltaY
);
bool PEPDFPageObjectSetTransformAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength,
    float pageA,
    float pageB,
    float pageC,
    float pageD,
    float pageE,
    float pageF
);
bool PEPDFPageObjectMoveToIndexAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength,
    int32_t destinationIndex
);
bool PEPDFPageObjectDeleteAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength
);
bool PEPDFPageObjectSetInvisibleAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength
);

bool PEPDFPageAddStandardText(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const uint16_t* text,
    size_t textLength,
    const char* fontName,
    float fontSize,
    float x,
    float y,
    uint32_t red,
    uint32_t green,
    uint32_t blue,
    uint32_t alpha
);
bool PEPDFPageAddJPEG(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const uint8_t* jpegBytes,
    size_t jpegLength,
    float x,
    float y,
    float width,
    float height
);
bool PEPDFPageAddBitmapBGRA(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const uint8_t* bitmapBytes,
    size_t bitmapLength,
    int32_t pixelWidth,
    int32_t pixelHeight,
    int32_t bytesPerRow,
    float x,
    float y,
    float width,
    float height
);
bool PEPDFPageObjectReplaceBitmapBGRAAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength,
    const uint8_t* bitmapBytes,
    size_t bitmapLength,
    int32_t pixelWidth,
    int32_t pixelHeight,
    int32_t bytesPerRow
);
bool PEPDFPageObjectCopyBitmapAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength,
    uint8_t** outputBytes,
    size_t* outputLength,
    int32_t* outputWidth,
    int32_t* outputHeight,
    int32_t* outputStride,
    int32_t* outputFormat
);
bool PEPDFPageImportOverlay(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const uint8_t* overlayPDFBytes,
    size_t overlayPDFLength
);
bool PEPDFPageImportOverlayWithActualText(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const uint8_t* overlayPDFBytes,
    size_t overlayPDFLength,
    const uint16_t* actualText,
    size_t actualTextLength
);

PEPDFFontRef PEPDFFontCreateEmbedded(
    PEPDFDocumentRef document,
    const uint8_t* fontBytes,
    size_t fontLength
);
void PEPDFFontClose(PEPDFFontRef font);
bool PEPDFPageAddEmbeddedText(
    PEPDFDocumentRef document,
    PEPDFFontRef font,
    int32_t pageIndex,
    const uint16_t* text,
    size_t textLength,
    float fontSize,
    float x,
    float y,
    bool invisible
);

void PEPDFFree(void* pointer);

#ifdef __cplusplus
}
#endif

#endif
