#include "PDFiumBridge.h"

#include <PDFium/fpdf_annot.h>
#include <PDFium/fpdf_edit.h>
#include <PDFium/fpdf_ppo.h>
#include <PDFium/fpdf_save.h>
#include <PDFium/fpdf_signature.h>
#include <PDFium/fpdf_text.h>
#include <PDFium/fpdfview.h>

#include <limits.h>
#include <stdlib.h>
#include <string.h>

typedef struct PERetainedSourceDocument {
    FPDF_DOCUMENT handle;
    uint8_t* bytes;
} PERetainedSourceDocument;

struct PEPDFDocument {
    FPDF_DOCUMENT handle;
    uint8_t* sourceBytes;
    size_t sourceLength;
    char* password;
    bool lastMutationRejectedForAppearance;
    PERetainedSourceDocument* retainedSources;
    size_t retainedSourceCount;
    size_t retainedSourceCapacity;
};

struct PEPDFFont {
    FPDF_FONT handle;
};

bool PEPDFAnnotationSetColor(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t annotationIndex,
    uint32_t red,
    uint32_t green,
    uint32_t blue,
    uint32_t alpha
) {
    if (document == NULL || document->handle == NULL || annotationIndex < 0 ||
        red > 255 || green > 255 || blue > 255 || alpha > 255) {
        return false;
    }
    FPDF_PAGE page = FPDF_LoadPage(document->handle, pageIndex);
    if (page == NULL || annotationIndex >= FPDFPage_GetAnnotCount(page)) {
        if (page != NULL) {
            FPDF_ClosePage(page);
        }
        return false;
    }
    FPDF_ANNOTATION annotation = FPDFPage_GetAnnot(page, annotationIndex);
    bool success = annotation != NULL && FPDFAnnot_SetColor(
        annotation,
        FPDFANNOT_COLORTYPE_Color,
        red,
        green,
        blue,
        alpha
    );
    FPDF_ANNOTATION_SUBTYPE subtype = annotation != NULL
        ? FPDFAnnot_GetSubtype(annotation)
        : FPDF_ANNOT_UNKNOWN;
    bool canRegenerateAppearance = subtype == FPDF_ANNOT_TEXT ||
        subtype == FPDF_ANNOT_HIGHLIGHT;
    if (!success && annotation != NULL && canRegenerateAppearance &&
        FPDFAnnot_SetAP(
            annotation,
            FPDF_ANNOT_APPEARANCEMODE_NORMAL,
            NULL
        )) {
        success = FPDFAnnot_SetColor(
            annotation,
            FPDFANNOT_COLORTYPE_Color,
            red,
            green,
            blue,
            alpha
        );
    }
    if (annotation != NULL) {
        FPDFPage_CloseAnnot(annotation);
    }
    FPDF_ClosePage(page);
    return success;
}

bool PEPDFAnnotationGetColor(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t annotationIndex,
    uint32_t* red,
    uint32_t* green,
    uint32_t* blue,
    uint32_t* alpha
) {
    if (document == NULL || document->handle == NULL || annotationIndex < 0 ||
        red == NULL || green == NULL || blue == NULL || alpha == NULL) {
        return false;
    }
    FPDF_PAGE page = FPDF_LoadPage(document->handle, pageIndex);
    if (page == NULL || annotationIndex >= FPDFPage_GetAnnotCount(page)) {
        if (page != NULL) {
            FPDF_ClosePage(page);
        }
        return false;
    }
    FPDF_ANNOTATION annotation = FPDFPage_GetAnnot(page, annotationIndex);
    bool success = annotation != NULL && FPDFAnnot_GetColor(
        annotation,
        FPDFANNOT_COLORTYPE_Color,
        red,
        green,
        blue,
        alpha
    );
    if (annotation != NULL) {
        FPDFPage_CloseAnnot(annotation);
    }
    FPDF_ClosePage(page);
    return success;
}

typedef struct PEWriteBuffer {
    FPDF_FILEWRITE writer;
    uint8_t* bytes;
    size_t length;
    size_t capacity;
} PEWriteBuffer;

typedef struct PEReadBuffer {
    const uint8_t* bytes;
    size_t length;
} PEReadBuffer;

typedef struct PEObjectContext {
    FPDF_PAGE page;
    FPDF_PAGEOBJECT object;
    FPDF_PAGEOBJECT parentForm;
    FS_MATRIX parentMatrix;
} PEObjectContext;

static const FS_MATRIX kPEIdentityMatrix = {1, 0, 0, 1, 0, 0};

static FS_MATRIX PEMatrixMultiply(FS_MATRIX parent, FS_MATRIX child) {
    FS_MATRIX result;
    result.a = parent.a * child.a + parent.c * child.b;
    result.b = parent.b * child.a + parent.d * child.b;
    result.c = parent.a * child.c + parent.c * child.d;
    result.d = parent.b * child.c + parent.d * child.d;
    result.e = parent.a * child.e + parent.c * child.f + parent.e;
    result.f = parent.b * child.e + parent.d * child.f + parent.f;
    return result;
}

static bool PEMatrixInvert(FS_MATRIX matrix, FS_MATRIX* output) {
    float determinant = matrix.a * matrix.d - matrix.b * matrix.c;
    if (output == NULL || (determinant > -0.000001f && determinant < 0.000001f)) {
        return false;
    }
    output->a = matrix.d / determinant;
    output->b = -matrix.b / determinant;
    output->c = -matrix.c / determinant;
    output->d = matrix.a / determinant;
    output->e = (matrix.c * matrix.f - matrix.d * matrix.e) / determinant;
    output->f = (matrix.b * matrix.e - matrix.a * matrix.f) / determinant;
    return true;
}

static FPDF_BITMAP PECreateBitmapBGRA(
    const uint8_t* bytes,
    size_t length,
    int32_t width,
    int32_t height,
    int32_t sourceStride
) {
    if (bytes == NULL || width <= 0 || width > INT_MAX / 4 || height <= 0 ||
        sourceStride < width * 4 ||
        (size_t)sourceStride > SIZE_MAX / (size_t)height ||
        length < (size_t)sourceStride * (size_t)height) {
        return NULL;
    }
    FPDF_BITMAP bitmap = FPDFBitmap_CreateEx(
        width, height, FPDFBitmap_BGRA, NULL, 0
    );
    if (bitmap == NULL) {
        return NULL;
    }
    uint8_t* destination = (uint8_t*)FPDFBitmap_GetBuffer(bitmap);
    int destinationStride = FPDFBitmap_GetStride(bitmap);
    if (destination == NULL || destinationStride < width * 4) {
        FPDFBitmap_Destroy(bitmap);
        return NULL;
    }
    for (int32_t row = 0; row < height; ++row) {
        memcpy(
            destination + (size_t)row * (size_t)destinationStride,
            bytes + (size_t)row * (size_t)sourceStride,
            (size_t)width * 4
        );
    }
    return bitmap;
}

static void PETransformPoint(
    FS_MATRIX matrix,
    float x,
    float y,
    float* outputX,
    float* outputY
) {
    *outputX = matrix.a * x + matrix.c * y + matrix.e;
    *outputY = matrix.b * x + matrix.d * y + matrix.f;
}

static int PEWriteBlock(
    struct FPDF_FILEWRITE_* writer,
    const void* data,
    unsigned long size
) {
    PEWriteBuffer* buffer = (PEWriteBuffer*)writer;
    size_t required = buffer->length + (size_t)size;
    if (required > buffer->capacity) {
        size_t capacity = buffer->capacity == 0 ? 65536 : buffer->capacity;
        while (capacity < required) {
            capacity *= 2;
        }

        uint8_t* bytes = (uint8_t*)realloc(buffer->bytes, capacity);
        if (bytes == NULL) {
            return 0;
        }
        buffer->bytes = bytes;
        buffer->capacity = capacity;
    }

    memcpy(buffer->bytes + buffer->length, data, (size_t)size);
    buffer->length = required;
    return 1;
}

static int PEReadBlock(
    void* parameter,
    unsigned long position,
    unsigned char* output,
    unsigned long size
) {
    PEReadBuffer* buffer = (PEReadBuffer*)parameter;
    size_t start = (size_t)position;
    size_t count = (size_t)size;
    if (start > buffer->length || count > buffer->length - start) {
        return 0;
    }
    memcpy(output, buffer->bytes + start, count);
    return 1;
}

static FPDF_PAGE PELoadPage(PEPDFDocumentRef document, int32_t pageIndex) {
    if (document == NULL || document->handle == NULL || pageIndex < 0 ||
        pageIndex >= FPDF_GetPageCount(document->handle)) {
        return NULL;
    }
    return FPDF_LoadPage(document->handle, pageIndex);
}

static bool PEEnsureRetainedSourceCapacity(PEPDFDocumentRef document) {
    if (document->retainedSourceCount < document->retainedSourceCapacity) {
        return true;
    }
    size_t capacity = document->retainedSourceCapacity == 0
        ? 4
        : document->retainedSourceCapacity * 2;
    PERetainedSourceDocument* sources =
        (PERetainedSourceDocument*)realloc(
            document->retainedSources,
            capacity * sizeof(PERetainedSourceDocument)
        );
    if (sources == NULL) {
        return false;
    }
    document->retainedSources = sources;
    document->retainedSourceCapacity = capacity;
    return true;
}

static FPDF_PAGEOBJECT PEGetObject(
    FPDF_PAGE page,
    int32_t objectIndex
) {
    if (page == NULL || objectIndex < 0 ||
        objectIndex >= FPDFPage_CountObjects(page)) {
        return NULL;
    }
    return FPDFPage_GetObject(page, objectIndex);
}

static int PERecursiveObjectCount(FPDF_PAGEOBJECT object) {
    if (object == NULL) {
        return 0;
    }
    int count = 1;
    if (FPDFPageObj_GetType(object) != FPDF_PAGEOBJ_FORM) {
        return count;
    }
    int childCount = FPDFFormObj_CountObjects(object);
    for (int index = 0; index < childCount; ++index) {
        count += PERecursiveObjectCount(
            FPDFFormObj_GetObject(object, (unsigned long)index)
        );
    }
    return count;
}

static bool PERecursiveObjectMetrics(
    FPDF_PAGEOBJECT object,
    size_t depth,
    size_t* objectCount,
    size_t* pathIndexCount
) {
    if (object == NULL || objectCount == NULL || pathIndexCount == NULL ||
        depth >= 64 || *objectCount == SIZE_MAX ||
        *pathIndexCount > SIZE_MAX - (depth + 1)) {
        return false;
    }
    *objectCount += 1;
    *pathIndexCount += depth + 1;
    if (FPDFPageObj_GetType(object) != FPDF_PAGEOBJ_FORM || depth >= 63) {
        return true;
    }
    int childCount = FPDFFormObj_CountObjects(object);
    for (int index = 0; index < childCount; ++index) {
        if (!PERecursiveObjectMetrics(
            FPDFFormObj_GetObject(object, (unsigned long)index),
            depth + 1,
            objectCount,
            pathIndexCount
        )) {
            return false;
        }
    }
    return true;
}

static bool PEFindObjectPath(
    FPDF_PAGEOBJECT object,
    int32_t objectIndex,
    int32_t targetFlatIndex,
    int32_t* currentFlatIndex,
    int32_t* path,
    size_t depth,
    int32_t** outputPath,
    size_t* outputLength
) {
    path[depth] = objectIndex;
    if (*currentFlatIndex == targetFlatIndex) {
        size_t length = depth + 1;
        int32_t* copiedPath = (int32_t*)malloc(length * sizeof(int32_t));
        if (copiedPath == NULL) {
            return false;
        }
        memcpy(copiedPath, path, length * sizeof(int32_t));
        *outputPath = copiedPath;
        *outputLength = length;
        return true;
    }
    *currentFlatIndex += 1;

    if (FPDFPageObj_GetType(object) != FPDF_PAGEOBJ_FORM || depth >= 63) {
        return false;
    }
    int childCount = FPDFFormObj_CountObjects(object);
    for (int childIndex = 0; childIndex < childCount; ++childIndex) {
        FPDF_PAGEOBJECT child = FPDFFormObj_GetObject(
            object,
            (unsigned long)childIndex
        );
        if (PEFindObjectPath(
            child,
            childIndex,
            targetFlatIndex,
            currentFlatIndex,
            path,
            depth + 1,
            outputPath,
            outputLength
        )) {
            return true;
        }
    }
    return false;
}

static bool PEResolveObject(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength,
    PEObjectContext* outputContext
) {
    if (path == NULL || pathLength == 0 || outputContext == NULL) {
        return false;
    }
    memset(outputContext, 0, sizeof(*outputContext));
    outputContext->parentMatrix = kPEIdentityMatrix;
    outputContext->page = PELoadPage(document, pageIndex);
    if (outputContext->page == NULL) {
        return false;
    }

    FPDF_PAGEOBJECT object = PEGetObject(outputContext->page, path[0]);
    if (object == NULL) {
        FPDF_ClosePage(outputContext->page);
        outputContext->page = NULL;
        return false;
    }
    for (size_t depth = 1; depth < pathLength; ++depth) {
        if (FPDFPageObj_GetType(object) != FPDF_PAGEOBJ_FORM) {
            FPDF_ClosePage(outputContext->page);
            outputContext->page = NULL;
            return false;
        }
        FS_MATRIX formMatrix = kPEIdentityMatrix;
        FPDFPageObj_GetMatrix(object, &formMatrix);
        outputContext->parentMatrix = PEMatrixMultiply(
            outputContext->parentMatrix,
            formMatrix
        );
        outputContext->parentForm = object;
        int childCount = FPDFFormObj_CountObjects(object);
        if (path[depth] < 0 || path[depth] >= childCount) {
            FPDF_ClosePage(outputContext->page);
            outputContext->page = NULL;
            return false;
        }
        object = FPDFFormObj_GetObject(object, (unsigned long)path[depth]);
        if (object == NULL) {
            FPDF_ClosePage(outputContext->page);
            outputContext->page = NULL;
            return false;
        }
    }
    outputContext->object = object;
    return true;
}

static bool PECloneFormAncestorsForEditing(
    FPDF_PAGE page,
    const int32_t* path,
    size_t pathLength
) {
    if (pathLength <= 1) {
        return true;
    }
    if (page == NULL || path == NULL) {
        return false;
    }

    FPDF_PAGEOBJECT form = PEGetObject(page, path[0]);
    for (size_t depth = 1; depth < pathLength; ++depth) {
        if (form == NULL || FPDFPageObj_GetType(form) != FPDF_PAGEOBJ_FORM ||
            !FPDFFormObj_CloneForEditing(form)) {
            return false;
        }
        if (depth + 1 < pathLength) {
            int childCount = FPDFFormObj_CountObjects(form);
            if (path[depth] < 0 || path[depth] >= childCount) {
                return false;
            }
            form = FPDFFormObj_GetObject(form, (unsigned long)path[depth]);
        }
    }
    return true;
}

static void PECloseObjectContext(PEObjectContext* context) {
    if (context != NULL && context->page != NULL) {
        FPDF_ClosePage(context->page);
        context->page = NULL;
    }
}

static void PEFillObjectInfo(
    FPDF_PAGEOBJECT object,
    FS_MATRIX parentMatrix,
    PEPDFObjectInfo* outputInfo
) {
    memset(outputInfo, 0, sizeof(*outputInfo));
    outputInfo->type = FPDFPageObj_GetType(object);
    float left = 0;
    float bottom = 0;
    float right = 0;
    float top = 0;
    if (FPDFPageObj_GetBounds(object, &left, &bottom, &right, &top)) {
        float x[4];
        float y[4];
        PETransformPoint(parentMatrix, left, bottom, &x[0], &y[0]);
        PETransformPoint(parentMatrix, right, bottom, &x[1], &y[1]);
        PETransformPoint(parentMatrix, left, top, &x[2], &y[2]);
        PETransformPoint(parentMatrix, right, top, &x[3], &y[3]);
        outputInfo->left = outputInfo->right = x[0];
        outputInfo->bottom = outputInfo->top = y[0];
        for (int index = 1; index < 4; ++index) {
            if (x[index] < outputInfo->left) outputInfo->left = x[index];
            if (x[index] > outputInfo->right) outputInfo->right = x[index];
            if (y[index] < outputInfo->bottom) outputInfo->bottom = y[index];
            if (y[index] > outputInfo->top) outputInfo->top = y[index];
        }
    }
    FS_MATRIX localMatrix = kPEIdentityMatrix;
    FPDFPageObj_GetMatrix(object, &localMatrix);
    FS_MATRIX pageMatrix = PEMatrixMultiply(parentMatrix, localMatrix);
    outputInfo->matrixA = pageMatrix.a;
    outputInfo->matrixB = pageMatrix.b;
    outputInfo->matrixC = pageMatrix.c;
    outputInfo->matrixD = pageMatrix.d;
    outputInfo->matrixE = pageMatrix.e;
    outputInfo->matrixF = pageMatrix.f;
    FPDFPageObj_GetFillColor(
        object,
        &outputInfo->fillRed,
        &outputInfo->fillGreen,
        &outputInfo->fillBlue,
        &outputInfo->fillAlpha
    );
    if (outputInfo->type == FPDF_PAGEOBJ_TEXT) {
        FPDFTextObj_GetFontSize(object, &outputInfo->fontSize);
    } else if (outputInfo->type == FPDF_PAGEOBJ_IMAGE) {
        FPDFImageObj_GetImagePixelSize(
            object,
            &outputInfo->imagePixelWidth,
            &outputInfo->imagePixelHeight
        );
    }
}

static bool PECollectDisplayObjects(
    FPDF_PAGEOBJECT object,
    int32_t objectIndex,
    FS_MATRIX parentMatrix,
    int32_t* path,
    size_t depth,
    int32_t* pathIndices,
    int32_t* pathOffsets,
    PEPDFObjectInfo* infos,
    size_t objectCapacity,
    size_t pathCapacity,
    size_t* objectPosition,
    size_t* pathPosition
) {
    if (object == NULL || depth >= 64 || *objectPosition >= objectCapacity ||
        *pathPosition > pathCapacity ||
        depth + 1 > pathCapacity - *pathPosition) {
        return false;
    }
    path[depth] = objectIndex;
    size_t outputIndex = *objectPosition;
    pathOffsets[outputIndex] = (int32_t)*pathPosition;
    memcpy(
        pathIndices + *pathPosition,
        path,
        (depth + 1) * sizeof(int32_t)
    );
    *pathPosition += depth + 1;
    PEFillObjectInfo(object, parentMatrix, &infos[outputIndex]);
    *objectPosition += 1;

    if (FPDFPageObj_GetType(object) != FPDF_PAGEOBJ_FORM || depth >= 63) {
        return true;
    }
    FS_MATRIX formMatrix = kPEIdentityMatrix;
    FPDFPageObj_GetMatrix(object, &formMatrix);
    FS_MATRIX childParentMatrix = PEMatrixMultiply(parentMatrix, formMatrix);
    int childCount = FPDFFormObj_CountObjects(object);
    for (int childIndex = 0; childIndex < childCount; ++childIndex) {
        if (!PECollectDisplayObjects(
            FPDFFormObj_GetObject(object, (unsigned long)childIndex),
            childIndex,
            childParentMatrix,
            path,
            depth + 1,
            pathIndices,
            pathOffsets,
            infos,
            objectCapacity,
            pathCapacity,
            objectPosition,
            pathPosition
        )) {
            return false;
        }
    }
    return true;
}

static uint16_t* PECopyWideString(
    const uint16_t* text,
    size_t length
) {
    uint16_t* copy = (uint16_t*)calloc(length + 1, sizeof(uint16_t));
    if (copy == NULL) {
        return NULL;
    }
    if (length > 0) {
        memcpy(copy, text, length * sizeof(uint16_t));
    }
    return copy;
}

void PEPDFLibraryInitialize(void) {
    FPDF_LIBRARY_CONFIG configuration;
    memset(&configuration, 0, sizeof(configuration));
    configuration.version = 2;
    FPDF_InitLibraryWithConfig(&configuration);
}

void PEPDFLibraryDestroy(void) {
    FPDF_DestroyLibrary();
}

PEPDFDocumentRef PEPDFDocumentCreate(
    const uint8_t* bytes,
    size_t length,
    const char* password,
    uint32_t* errorCode
) {
    if (errorCode != NULL) {
        *errorCode = 0;
    }
    if (bytes == NULL || length == 0) {
        return NULL;
    }

    PEPDFDocumentRef document =
        (PEPDFDocumentRef)calloc(1, sizeof(struct PEPDFDocument));
    if (document == NULL) {
        return NULL;
    }
    document->sourceBytes = (uint8_t*)malloc(length);
    if (document->sourceBytes == NULL) {
        free(document);
        return NULL;
    }
    memcpy(document->sourceBytes, bytes, length);
    document->sourceLength = length;
    if (password != NULL) {
        size_t passwordLength = strlen(password);
        document->password = (char*)malloc(passwordLength + 1);
        if (document->password == NULL) {
            free(document->sourceBytes);
            free(document);
            return NULL;
        }
        memcpy(document->password, password, passwordLength + 1);
    }
    document->handle = FPDF_LoadMemDocument64(
        document->sourceBytes,
        length,
        document->password
    );
    if (document->handle == NULL) {
        if (errorCode != NULL) {
            *errorCode = (uint32_t)FPDF_GetLastError();
        }
        free(document->password);
        free(document->sourceBytes);
        free(document);
        return NULL;
    }
    return document;
}

void PEPDFDocumentClose(PEPDFDocumentRef document) {
    if (document == NULL) {
        return;
    }
    if (document->handle != NULL) {
        FPDF_CloseDocument(document->handle);
    }
    for (size_t index = 0; index < document->retainedSourceCount; ++index) {
        FPDF_CloseDocument(document->retainedSources[index].handle);
        free(document->retainedSources[index].bytes);
    }
    free(document->retainedSources);
    free(document->password);
    free(document->sourceBytes);
    free(document);
}

int32_t PEPDFDocumentPageCount(PEPDFDocumentRef document) {
    if (document == NULL || document->handle == NULL) {
        return 0;
    }
    return FPDF_GetPageCount(document->handle);
}

bool PEPDFDocumentLastMutationRejectedForAppearance(
    PEPDFDocumentRef document
) {
    return document != NULL && document->lastMutationRejectedForAppearance;
}

bool PEPDFDocumentIsEncrypted(PEPDFDocumentRef document) {
    return document != NULL && document->handle != NULL &&
        FPDF_GetSecurityHandlerRevision(document->handle) >= 0;
}

uint32_t PEPDFDocumentPermissions(PEPDFDocumentRef document) {
    if (document == NULL || document->handle == NULL) {
        return 0;
    }
    return (uint32_t)FPDF_GetDocPermissions(document->handle);
}

int32_t PEPDFDocumentSignatureCount(PEPDFDocumentRef document) {
    if (document == NULL || document->handle == NULL) {
        return 0;
    }
    return FPDF_GetSignatureCount(document->handle);
}

bool PEPDFPageInfoAtIndex(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    PEPDFPageInfo* outputInfo
) {
    if (document == NULL || document->handle == NULL || outputInfo == NULL) {
        return false;
    }
    FS_SIZEF size;
    if (!FPDF_GetPageSizeByIndexF(document->handle, pageIndex, &size)) {
        return false;
    }
    FPDF_PAGE page = PELoadPage(document, pageIndex);
    if (page == NULL) {
        return false;
    }
    int rotation = FPDFPage_GetRotation(page);
    FPDF_ClosePage(page);
    if (rotation < 0) {
        return false;
    }
    outputInfo->width = size.width;
    outputInfo->height = size.height;
    outputInfo->rotation = rotation;
    return true;
}

bool PEPDFDocumentDeletePage(
    PEPDFDocumentRef document,
    int32_t pageIndex
) {
    if (document == NULL || document->handle == NULL || pageIndex < 0 ||
        pageIndex >= FPDF_GetPageCount(document->handle)) {
        return false;
    }
    int previousCount = FPDF_GetPageCount(document->handle);
    FPDFPage_Delete(document->handle, pageIndex);
    return FPDF_GetPageCount(document->handle) == previousCount - 1;
}

bool PEPDFDocumentSetPageRotation(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t quarterTurnsClockwise
) {
    if (quarterTurnsClockwise < 0 || quarterTurnsClockwise > 3) {
        return false;
    }
    FPDF_PAGE page = PELoadPage(document, pageIndex);
    if (page == NULL) {
        return false;
    }
    FPDFPage_SetRotation(page, quarterTurnsClockwise);
    bool success = FPDFPage_GetRotation(page) == quarterTurnsClockwise;
    FPDF_ClosePage(page);
    return success;
}

bool PEPDFDocumentMovePages(
    PEPDFDocumentRef document,
    const int32_t* pageIndices,
    size_t pageIndicesLength,
    int32_t destinationIndex
) {
    if (document == NULL || document->handle == NULL || pageIndices == NULL ||
        pageIndicesLength == 0 || pageIndicesLength > ULONG_MAX ||
        destinationIndex < 0) {
        return false;
    }
    return FPDF_MovePages(
        document->handle,
        (const int*)pageIndices,
        (unsigned long)pageIndicesLength,
        destinationIndex
    );
}

bool PEPDFDocumentImportPages(
    PEPDFDocumentRef document,
    const uint8_t* sourceBytes,
    size_t sourceLength,
    const char* password,
    int32_t destinationIndex,
    uint32_t* errorCode
) {
    if (errorCode != NULL) {
        *errorCode = 0;
    }
    if (document == NULL || document->handle == NULL || sourceBytes == NULL ||
        sourceLength == 0 || destinationIndex < 0 ||
        destinationIndex > FPDF_GetPageCount(document->handle)) {
        return false;
    }
    if (!PEEnsureRetainedSourceCapacity(document)) {
        return false;
    }
    uint8_t* retainedBytes = (uint8_t*)malloc(sourceLength);
    if (retainedBytes == NULL) {
        return false;
    }
    memcpy(retainedBytes, sourceBytes, sourceLength);
    FPDF_DOCUMENT source = FPDF_LoadMemDocument64(
        retainedBytes,
        sourceLength,
        password
    );
    if (source == NULL) {
        if (errorCode != NULL) {
            *errorCode = (uint32_t)FPDF_GetLastError();
        }
        free(retainedBytes);
        return false;
    }
    bool success = FPDF_ImportPagesByIndex(
        document->handle,
        source,
        NULL,
        0,
        destinationIndex
    );
    if (success) {
        PERetainedSourceDocument retained = {source, retainedBytes};
        document->retainedSources[document->retainedSourceCount] = retained;
        document->retainedSourceCount += 1;
    } else {
        FPDF_CloseDocument(source);
        free(retainedBytes);
    }
    return success;
}

static bool PECopyDocumentData(
    FPDF_DOCUMENT document,
    int flags,
    uint8_t** outputBytes,
    size_t* outputLength
) {
    if (document == NULL || outputBytes == NULL || outputLength == NULL) {
        return false;
    }
    PEWriteBuffer buffer;
    memset(&buffer, 0, sizeof(buffer));
    buffer.writer.version = 1;
    buffer.writer.WriteBlock = PEWriteBlock;
    if (!FPDF_SaveAsCopy(document, &buffer.writer, flags)) {
        free(buffer.bytes);
        return false;
    }
    *outputBytes = buffer.bytes;
    *outputLength = buffer.length;
    return true;
}

static void PEClearRetainedSources(PEPDFDocumentRef document) {
    for (size_t index = 0; index < document->retainedSourceCount; ++index) {
        FPDF_CloseDocument(document->retainedSources[index].handle);
        free(document->retainedSources[index].bytes);
    }
    free(document->retainedSources);
    document->retainedSources = NULL;
    document->retainedSourceCount = 0;
    document->retainedSourceCapacity = 0;
}

static bool PEReloadDocumentFromData(
    PEPDFDocumentRef document,
    const uint8_t* bytes,
    size_t length
) {
    if (document == NULL || bytes == NULL || length == 0) {
        return false;
    }
    uint8_t* copiedBytes = (uint8_t*)malloc(length);
    if (copiedBytes == NULL) {
        return false;
    }
    memcpy(copiedBytes, bytes, length);
    FPDF_DOCUMENT replacement = FPDF_LoadMemDocument64(
        copiedBytes,
        length,
        document->password
    );
    if (replacement == NULL) {
        free(copiedBytes);
        return false;
    }
    FPDF_CloseDocument(document->handle);
    PEClearRetainedSources(document);
    free(document->sourceBytes);
    document->handle = replacement;
    document->sourceBytes = copiedBytes;
    document->sourceLength = length;
    return true;
}

bool PEPDFDocumentCopyPages(
    PEPDFDocumentRef document,
    const int32_t* pageIndices,
    size_t pageIndicesLength,
    uint8_t** outputBytes,
    size_t* outputLength
) {
    if (document == NULL || document->handle == NULL || pageIndices == NULL ||
        pageIndicesLength == 0 || pageIndicesLength > ULONG_MAX ||
        outputBytes == NULL || outputLength == NULL) {
        return false;
    }
    FPDF_DOCUMENT output = FPDF_CreateNewDocument();
    if (output == NULL) {
        return false;
    }
    bool success = FPDF_ImportPagesByIndex(
        output,
        document->handle,
        (const int*)pageIndices,
        (unsigned long)pageIndicesLength,
        0
    );
    if (success) {
        FPDF_CopyViewerPreferences(output, document->handle);
        success = PECopyDocumentData(
            output,
            FPDF_NO_INCREMENTAL | FPDF_SUBSET_NEW_FONTS,
            outputBytes,
            outputLength
        );
    }
    FPDF_CloseDocument(output);
    return success;
}

bool PEPDFDocumentCopyData(
    PEPDFDocumentRef document,
    bool removeSecurity,
    uint8_t** outputBytes,
    size_t* outputLength
) {
    if (document == NULL || document->handle == NULL || outputBytes == NULL ||
        outputLength == NULL) {
        return false;
    }

    int flags = FPDF_NO_INCREMENTAL | FPDF_SUBSET_NEW_FONTS;
    if (removeSecurity) {
        flags |= FPDF_REMOVE_SECURITY;
    }
    return PECopyDocumentData(
        document->handle,
        flags,
        outputBytes,
        outputLength
    );
}

int32_t PEPDFPageObjectCount(PEPDFDocumentRef document, int32_t pageIndex) {
    FPDF_PAGE page = PELoadPage(document, pageIndex);
    if (page == NULL) {
        return 0;
    }
    int count = FPDFPage_CountObjects(page);
    FPDF_ClosePage(page);
    return count;
}

int32_t PEPDFPageObjectCountRecursive(
    PEPDFDocumentRef document,
    int32_t pageIndex
) {
    FPDF_PAGE page = PELoadPage(document, pageIndex);
    if (page == NULL) {
        return 0;
    }
    int count = 0;
    int topLevelCount = FPDFPage_CountObjects(page);
    for (int index = 0; index < topLevelCount; ++index) {
        count += PERecursiveObjectCount(FPDFPage_GetObject(page, index));
    }
    FPDF_ClosePage(page);
    return count;
}

bool PEPDFPageObjectCopyPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t flatIndex,
    int32_t** outputIndices,
    size_t* outputLength
) {
    if (flatIndex < 0 || outputIndices == NULL || outputLength == NULL) {
        return false;
    }
    *outputIndices = NULL;
    *outputLength = 0;
    FPDF_PAGE page = PELoadPage(document, pageIndex);
    if (page == NULL) {
        return false;
    }
    int32_t currentFlatIndex = 0;
    int32_t path[64];
    int topLevelCount = FPDFPage_CountObjects(page);
    bool found = false;
    for (int index = 0; index < topLevelCount; ++index) {
        found = PEFindObjectPath(
            FPDFPage_GetObject(page, index),
            index,
            flatIndex,
            &currentFlatIndex,
            path,
            0,
            outputIndices,
            outputLength
        );
        if (found) {
            break;
        }
    }
    FPDF_ClosePage(page);
    return found;
}

bool PEPDFPageObjectCopyDisplayList(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t** outputPathIndices,
    int32_t** outputPathOffsets,
    PEPDFObjectInfo** outputInfos,
    size_t* outputObjectCount,
    size_t* outputPathIndexCount
) {
    if (outputPathIndices == NULL || outputPathOffsets == NULL ||
        outputInfos == NULL || outputObjectCount == NULL ||
        outputPathIndexCount == NULL) {
        return false;
    }
    *outputPathIndices = NULL;
    *outputPathOffsets = NULL;
    *outputInfos = NULL;
    *outputObjectCount = 0;
    *outputPathIndexCount = 0;

    FPDF_PAGE page = PELoadPage(document, pageIndex);
    if (page == NULL) {
        return false;
    }

    size_t objectCount = 0;
    size_t pathIndexCount = 0;
    int topLevelCount = FPDFPage_CountObjects(page);
    bool success = true;
    for (int index = 0; index < topLevelCount && success; ++index) {
        success = PERecursiveObjectMetrics(
            FPDFPage_GetObject(page, index),
            0,
            &objectCount,
            &pathIndexCount
        );
    }
    if (!success || objectCount > INT32_MAX || pathIndexCount > INT32_MAX ||
        objectCount > (SIZE_MAX / sizeof(PEPDFObjectInfo)) ||
        pathIndexCount > (SIZE_MAX / sizeof(int32_t)) ||
        objectCount + 1 > (SIZE_MAX / sizeof(int32_t))) {
        FPDF_ClosePage(page);
        return false;
    }
    if (objectCount == 0) {
        FPDF_ClosePage(page);
        return true;
    }

    int32_t* pathIndices = (int32_t*)malloc(
        pathIndexCount * sizeof(int32_t)
    );
    int32_t* pathOffsets = (int32_t*)malloc(
        (objectCount + 1) * sizeof(int32_t)
    );
    PEPDFObjectInfo* infos = (PEPDFObjectInfo*)calloc(
        objectCount,
        sizeof(PEPDFObjectInfo)
    );
    if (pathIndices == NULL || pathOffsets == NULL || infos == NULL) {
        free(pathIndices);
        free(pathOffsets);
        free(infos);
        FPDF_ClosePage(page);
        return false;
    }

    int32_t path[64];
    size_t objectPosition = 0;
    size_t pathPosition = 0;
    for (int index = 0; index < topLevelCount && success; ++index) {
        success = PECollectDisplayObjects(
            FPDFPage_GetObject(page, index),
            index,
            kPEIdentityMatrix,
            path,
            0,
            pathIndices,
            pathOffsets,
            infos,
            objectCount,
            pathIndexCount,
            &objectPosition,
            &pathPosition
        );
    }
    FPDF_ClosePage(page);
    if (!success || objectPosition != objectCount ||
        pathPosition != pathIndexCount) {
        free(pathIndices);
        free(pathOffsets);
        free(infos);
        return false;
    }

    pathOffsets[objectCount] = (int32_t)pathIndexCount;
    *outputPathIndices = pathIndices;
    *outputPathOffsets = pathOffsets;
    *outputInfos = infos;
    *outputObjectCount = objectCount;
    *outputPathIndexCount = pathIndexCount;
    return true;
}

bool PEPDFPageObjectInfoAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength,
    PEPDFObjectInfo* outputInfo
) {
    if (outputInfo == NULL) {
        return false;
    }
    PEObjectContext context = {0};
    if (!PEResolveObject(document, pageIndex, path, pathLength, &context)) {
        return false;
    }

    PEFillObjectInfo(context.object, context.parentMatrix, outputInfo);
    PECloseObjectContext(&context);
    return true;
}

bool PEPDFPageObjectInfo(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t objectIndex,
    PEPDFObjectInfo* outputInfo
) {
    if (outputInfo == NULL) {
        return false;
    }
    FPDF_PAGE page = PELoadPage(document, pageIndex);
    FPDF_PAGEOBJECT object = PEGetObject(page, objectIndex);
    if (object == NULL) {
        if (page != NULL) FPDF_ClosePage(page);
        return false;
    }

    memset(outputInfo, 0, sizeof(*outputInfo));
    outputInfo->type = FPDFPageObj_GetType(object);
    FPDFPageObj_GetBounds(
        object,
        &outputInfo->left,
        &outputInfo->bottom,
        &outputInfo->right,
        &outputInfo->top
    );
    FS_MATRIX matrix;
    if (FPDFPageObj_GetMatrix(object, &matrix)) {
        outputInfo->matrixA = matrix.a;
        outputInfo->matrixB = matrix.b;
        outputInfo->matrixC = matrix.c;
        outputInfo->matrixD = matrix.d;
        outputInfo->matrixE = matrix.e;
        outputInfo->matrixF = matrix.f;
    }
    FPDFPageObj_GetFillColor(
        object,
        &outputInfo->fillRed,
        &outputInfo->fillGreen,
        &outputInfo->fillBlue,
        &outputInfo->fillAlpha
    );
    if (outputInfo->type == FPDF_PAGEOBJ_TEXT) {
        FPDFTextObj_GetFontSize(object, &outputInfo->fontSize);
    }
    FPDF_ClosePage(page);
    return true;
}

bool PEPDFPageObjectCopyText(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t objectIndex,
    uint16_t** outputText,
    size_t* outputLength
) {
    if (outputText == NULL || outputLength == NULL) {
        return false;
    }
    *outputText = NULL;
    *outputLength = 0;
    FPDF_PAGE page = PELoadPage(document, pageIndex);
    FPDF_PAGEOBJECT object = PEGetObject(page, objectIndex);
    if (object == NULL || FPDFPageObj_GetType(object) != FPDF_PAGEOBJ_TEXT) {
        if (page != NULL) FPDF_ClosePage(page);
        return false;
    }
    FPDF_TEXTPAGE textPage = FPDFText_LoadPage(page);
    if (textPage == NULL) {
        FPDF_ClosePage(page);
        return false;
    }
    unsigned long byteCount = FPDFTextObj_GetText(object, textPage, NULL, 0);
    if (byteCount < sizeof(uint16_t)) {
        FPDFText_ClosePage(textPage);
        FPDF_ClosePage(page);
        return false;
    }
    uint16_t* text = (uint16_t*)malloc((size_t)byteCount);
    if (text == NULL ||
        FPDFTextObj_GetText(object, textPage, text, byteCount) == 0) {
        free(text);
        FPDFText_ClosePage(textPage);
        FPDF_ClosePage(page);
        return false;
    }
    *outputText = text;
    *outputLength = (size_t)byteCount / sizeof(uint16_t) - 1;
    FPDFText_ClosePage(textPage);
    FPDF_ClosePage(page);
    return true;
}

bool PEPDFPageObjectCopyFontName(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t objectIndex,
    char** outputName,
    size_t* outputLength
) {
    if (outputName == NULL || outputLength == NULL) {
        return false;
    }
    *outputName = NULL;
    *outputLength = 0;
    FPDF_PAGE page = PELoadPage(document, pageIndex);
    FPDF_PAGEOBJECT object = PEGetObject(page, objectIndex);
    if (object == NULL || FPDFPageObj_GetType(object) != FPDF_PAGEOBJ_TEXT) {
        if (page != NULL) FPDF_ClosePage(page);
        return false;
    }
    FPDF_FONT font = FPDFTextObj_GetFont(object);
    size_t length = FPDFFont_GetBaseFontName(font, NULL, 0);
    if (length == 0) {
        FPDF_ClosePage(page);
        return false;
    }
    char* name = (char*)malloc(length);
    if (name == NULL || FPDFFont_GetBaseFontName(font, name, length) == 0) {
        free(name);
        FPDF_ClosePage(page);
        return false;
    }
    *outputName = name;
    *outputLength = length - 1;
    FPDF_ClosePage(page);
    return true;
}

bool PEPDFPageObjectCopyTextAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength,
    uint16_t** outputText,
    size_t* outputLength
) {
    if (outputText == NULL || outputLength == NULL) {
        return false;
    }
    *outputText = NULL;
    *outputLength = 0;
    PEObjectContext context = {0};
    if (!PEResolveObject(document, pageIndex, path, pathLength, &context) ||
        FPDFPageObj_GetType(context.object) != FPDF_PAGEOBJ_TEXT) {
        PECloseObjectContext(&context);
        return false;
    }
    FPDF_TEXTPAGE textPage = FPDFText_LoadPage(context.page);
    if (textPage == NULL) {
        PECloseObjectContext(&context);
        return false;
    }
    unsigned long byteCount = FPDFTextObj_GetText(
        context.object,
        textPage,
        NULL,
        0
    );
    uint16_t* text = byteCount >= sizeof(uint16_t)
        ? (uint16_t*)malloc((size_t)byteCount)
        : NULL;
    bool success = text != NULL && FPDFTextObj_GetText(
        context.object,
        textPage,
        text,
        byteCount
    ) > 0;
    if (success) {
        *outputText = text;
        *outputLength = (size_t)byteCount / sizeof(uint16_t) - 1;
    } else {
        free(text);
    }
    FPDFText_ClosePage(textPage);
    PECloseObjectContext(&context);
    return success;
}

bool PEPDFPageObjectCopyFontNameAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength,
    char** outputName,
    size_t* outputLength
) {
    if (outputName == NULL || outputLength == NULL) {
        return false;
    }
    *outputName = NULL;
    *outputLength = 0;
    PEObjectContext context = {0};
    if (!PEResolveObject(document, pageIndex, path, pathLength, &context) ||
        FPDFPageObj_GetType(context.object) != FPDF_PAGEOBJ_TEXT) {
        PECloseObjectContext(&context);
        return false;
    }
    FPDF_FONT font = FPDFTextObj_GetFont(context.object);
    size_t length = FPDFFont_GetBaseFontName(font, NULL, 0);
    char* name = length > 0 ? (char*)malloc(length) : NULL;
    bool success = name != NULL &&
        FPDFFont_GetBaseFontName(font, name, length) > 0;
    if (success) {
        *outputName = name;
        *outputLength = length - 1;
    } else {
        free(name);
    }
    PECloseObjectContext(&context);
    return success;
}

bool PEPDFPageObjectCopyFontDataAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength,
    uint8_t** outputBytes,
    size_t* outputLength
) {
    if (outputBytes == NULL || outputLength == NULL) {
        return false;
    }
    *outputBytes = NULL;
    *outputLength = 0;
    PEObjectContext context = {0};
    if (!PEResolveObject(document, pageIndex, path, pathLength, &context) ||
        FPDFPageObj_GetType(context.object) != FPDF_PAGEOBJ_TEXT) {
        PECloseObjectContext(&context);
        return false;
    }
    FPDF_FONT font = FPDFTextObj_GetFont(context.object);
    size_t length = 0;
    bool measured = FPDFFont_GetFontData(font, NULL, 0, &length);
    uint8_t* bytes = measured && length > 0 ? (uint8_t*)malloc(length) : NULL;
    bool success = bytes != NULL &&
        FPDFFont_GetFontData(font, bytes, length, &length);
    if (success) {
        *outputBytes = bytes;
        *outputLength = length;
    } else {
        free(bytes);
    }
    PECloseObjectContext(&context);
    return success;
}

typedef struct PEPageColorMetrics {
    uint64_t sampledPixels;
    uint64_t chromaticPixels;
    uint64_t chromaSum;
} PEPageColorMetrics;

static bool PEPageObjectBoundsInPage(
    PEObjectContext context,
    float* left,
    float* bottom,
    float* right,
    float* top
) {
    float localLeft = 0;
    float localBottom = 0;
    float localRight = 0;
    float localTop = 0;
    if (!FPDFPageObj_GetBounds(
        context.object,
        &localLeft,
        &localBottom,
        &localRight,
        &localTop
    )) {
        return false;
    }
    float x[4];
    float y[4];
    PETransformPoint(context.parentMatrix, localLeft, localBottom, &x[0], &y[0]);
    PETransformPoint(context.parentMatrix, localRight, localBottom, &x[1], &y[1]);
    PETransformPoint(context.parentMatrix, localLeft, localTop, &x[2], &y[2]);
    PETransformPoint(context.parentMatrix, localRight, localTop, &x[3], &y[3]);
    *left = *right = x[0];
    *bottom = *top = y[0];
    for (int index = 1; index < 4; ++index) {
        if (x[index] < *left) *left = x[index];
        if (x[index] > *right) *right = x[index];
        if (y[index] < *bottom) *bottom = y[index];
        if (y[index] > *top) *top = y[index];
    }
    return true;
}

static bool PEPageColorMetricsCreate(
    FPDF_PAGE page,
    float excludedLeft,
    float excludedBottom,
    float excludedRight,
    float excludedTop,
    PEPageColorMetrics* output
) {
    if (page == NULL || output == NULL) {
        return false;
    }
    float pageWidth = FPDF_GetPageWidthF(page);
    float pageHeight = FPDF_GetPageHeightF(page);
    if (pageWidth <= 0 || pageHeight <= 0) {
        return false;
    }
    const int maximumDimension = 256;
    float scale = (float)maximumDimension /
        (pageWidth > pageHeight ? pageWidth : pageHeight);
    int width = (int)(pageWidth * scale + 0.5f);
    int height = (int)(pageHeight * scale + 0.5f);
    if (width < 1) width = 1;
    if (height < 1) height = 1;
    FPDF_BITMAP bitmap = FPDFBitmap_CreateEx(
        width,
        height,
        FPDFBitmap_BGRA,
        NULL,
        0
    );
    if (bitmap == NULL) {
        return false;
    }
    FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xFFFFFFFF);
    FPDF_RenderPageBitmap(bitmap, page, 0, 0, width, height, 0, 0);
    uint8_t* bytes = (uint8_t*)FPDFBitmap_GetBuffer(bitmap);
    int stride = FPDFBitmap_GetStride(bitmap);
    if (bytes == NULL || stride < width * 4) {
        FPDFBitmap_Destroy(bitmap);
        return false;
    }
    memset(output, 0, sizeof(*output));
    const float margin = 4.0f;
    excludedLeft -= margin;
    excludedBottom -= margin;
    excludedRight += margin;
    excludedTop += margin;
    for (int row = 0; row < height; ++row) {
        float pageY = pageHeight * (1.0f - ((float)row + 0.5f) / (float)height);
        const uint8_t* scanline = bytes + (size_t)row * (size_t)stride;
        for (int column = 0; column < width; ++column) {
            float pageX = pageWidth * ((float)column + 0.5f) / (float)width;
            if (pageX >= excludedLeft && pageX <= excludedRight &&
                pageY >= excludedBottom && pageY <= excludedTop) {
                continue;
            }
            const uint8_t* pixel = scanline + (size_t)column * 4;
            uint8_t blue = pixel[0];
            uint8_t green = pixel[1];
            uint8_t red = pixel[2];
            uint8_t maximum = red > green ? red : green;
            if (blue > maximum) maximum = blue;
            uint8_t minimum = red < green ? red : green;
            if (blue < minimum) minimum = blue;
            uint8_t chroma = maximum - minimum;
            output->sampledPixels += 1;
            output->chromaSum += chroma;
            if (chroma >= 12) {
                output->chromaticPixels += 1;
            }
        }
    }
    FPDFBitmap_Destroy(bitmap);
    return true;
}

static bool PEPageColorsPreserved(
    PEPageColorMetrics before,
    PEPageColorMetrics after
) {
    if (before.chromaticPixels < 16 || before.chromaSum < 512) {
        return true;
    }
    return after.chromaticPixels * 4 >= before.chromaticPixels &&
        after.chromaSum * 4 >= before.chromaSum;
}

static bool PESerializedPageColorMetricsCreate(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    float excludedLeft,
    float excludedBottom,
    float excludedRight,
    float excludedTop,
    PEPageColorMetrics* output
) {
    uint8_t* bytes = NULL;
    size_t length = 0;
    if (!PECopyDocumentData(
        document->handle,
        FPDF_NO_INCREMENTAL | FPDF_SUBSET_NEW_FONTS,
        &bytes,
        &length
    )) {
        return false;
    }
    FPDF_DOCUMENT reopened = FPDF_LoadMemDocument64(
        bytes,
        length,
        document->password
    );
    FPDF_PAGE page = reopened == NULL ? NULL : FPDF_LoadPage(reopened, pageIndex);
    bool success = PEPageColorMetricsCreate(
        page,
        excludedLeft,
        excludedBottom,
        excludedRight,
        excludedTop,
        output
    );
    if (page != NULL) FPDF_ClosePage(page);
    if (reopened != NULL) FPDF_CloseDocument(reopened);
    free(bytes);
    return success;
}

bool PEPDFPageObjectReplaceText(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t objectIndex,
    const uint16_t* text,
    size_t textLength
) {
    if (document != NULL) {
        document->lastMutationRejectedForAppearance = false;
    }
    FPDF_PAGE page = PELoadPage(document, pageIndex);
    FPDF_PAGEOBJECT object = PEGetObject(page, objectIndex);
    if (object == NULL || FPDFPageObj_GetType(object) != FPDF_PAGEOBJ_TEXT) {
        if (page != NULL) FPDF_ClosePage(page);
        return false;
    }
    float excludedLeft = 0;
    float excludedBottom = 0;
    float excludedRight = 0;
    float excludedTop = 0;
    PEObjectContext context = {
        page,
        object,
        NULL,
        kPEIdentityMatrix
    };
    PEPageColorMetrics beforeMetrics;
    uint8_t* beforeBytes = NULL;
    size_t beforeLength = 0;
    bool prepared = PEPageObjectBoundsInPage(
        context,
        &excludedLeft,
        &excludedBottom,
        &excludedRight,
        &excludedTop
    ) && PEPageColorMetricsCreate(
        page,
        excludedLeft,
        excludedBottom,
        excludedRight,
        excludedTop,
        &beforeMetrics
    ) && PECopyDocumentData(
        document->handle,
        FPDF_NO_INCREMENTAL | FPDF_SUBSET_NEW_FONTS,
        &beforeBytes,
        &beforeLength
    );
    if (!prepared) {
        document->lastMutationRejectedForAppearance = true;
        free(beforeBytes);
        FPDF_ClosePage(page);
        return false;
    }
    uint16_t* terminatedText = PECopyWideString(text, textLength);
    bool success = terminatedText != NULL &&
        FPDFText_SetText(object, terminatedText) &&
        FPDFPage_GenerateContent(page);
    free(terminatedText);
    PEPageColorMetrics afterMetrics;
    if (success) {
        bool measured = PESerializedPageColorMetricsCreate(
            document,
            pageIndex,
            excludedLeft,
            excludedBottom,
            excludedRight,
            excludedTop,
            &afterMetrics
        );
        bool preserved = measured && PEPageColorsPreserved(beforeMetrics, afterMetrics);
        if (!preserved) {
            document->lastMutationRejectedForAppearance = true;
        }
        success = preserved;
    }
    FPDF_ClosePage(page);
    if (!success) {
        PEReloadDocumentFromData(document, beforeBytes, beforeLength);
    }
    free(beforeBytes);
    return success;
}

bool PEPDFPageObjectTranslate(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t objectIndex,
    float deltaX,
    float deltaY
) {
    FPDF_PAGE page = PELoadPage(document, pageIndex);
    FPDF_PAGEOBJECT object = PEGetObject(page, objectIndex);
    FS_MATRIX matrix;
    bool success = object != NULL && FPDFPageObj_GetMatrix(object, &matrix);
    if (success) {
        matrix.e += deltaX;
        matrix.f += deltaY;
        success = FPDFPageObj_SetMatrix(object, &matrix) &&
            FPDFPage_GenerateContent(page);
    }
    if (page != NULL) FPDF_ClosePage(page);
    return success;
}

bool PEPDFPageObjectDelete(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    int32_t objectIndex
) {
    FPDF_PAGE page = PELoadPage(document, pageIndex);
    FPDF_PAGEOBJECT object = PEGetObject(page, objectIndex);
    bool success = object != NULL && FPDFPage_RemoveObject(page, object);
    if (success) {
        FPDFPageObj_Destroy(object);
        success = FPDFPage_GenerateContent(page);
    }
    if (page != NULL) FPDF_ClosePage(page);
    return success;
}

bool PEPDFPageObjectReplaceTextAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength,
    const uint16_t* text,
    size_t textLength
) {
    if (document != NULL) {
        document->lastMutationRejectedForAppearance = false;
    }
    PEObjectContext context = {0};
    if (!PEResolveObject(document, pageIndex, path, pathLength, &context) ||
        FPDFPageObj_GetType(context.object) != FPDF_PAGEOBJ_TEXT) {
        PECloseObjectContext(&context);
        return false;
    }
    float excludedLeft = 0;
    float excludedBottom = 0;
    float excludedRight = 0;
    float excludedTop = 0;
    PEPageColorMetrics beforeMetrics;
    uint8_t* beforeBytes = NULL;
    size_t beforeLength = 0;
    bool prepared = PEPageObjectBoundsInPage(
        context,
        &excludedLeft,
        &excludedBottom,
        &excludedRight,
        &excludedTop
    ) && PEPageColorMetricsCreate(
        context.page,
        excludedLeft,
        excludedBottom,
        excludedRight,
        excludedTop,
        &beforeMetrics
    ) && PECopyDocumentData(
        document->handle,
        FPDF_NO_INCREMENTAL | FPDF_SUBSET_NEW_FONTS,
        &beforeBytes,
        &beforeLength
    );
    if (!prepared) {
        document->lastMutationRejectedForAppearance = true;
        free(beforeBytes);
        PECloseObjectContext(&context);
        return false;
    }
    uint16_t* terminatedText = PECopyWideString(text, textLength);
    bool success = terminatedText != NULL &&
        PECloneFormAncestorsForEditing(context.page, path, pathLength) &&
        FPDFText_SetText(context.object, terminatedText) &&
        FPDFPage_GenerateContent(context.page);
    free(terminatedText);
    PEPageColorMetrics afterMetrics;
    if (success) {
        bool measured = PESerializedPageColorMetricsCreate(
            document,
            pageIndex,
            excludedLeft,
            excludedBottom,
            excludedRight,
            excludedTop,
            &afterMetrics
        );
        bool preserved = measured && PEPageColorsPreserved(beforeMetrics, afterMetrics);
        if (!preserved) {
            document->lastMutationRejectedForAppearance = true;
        }
        success = preserved;
    }
    PECloseObjectContext(&context);
    if (!success) {
        PEReloadDocumentFromData(document, beforeBytes, beforeLength);
    }
    free(beforeBytes);
    return success;
}

bool PEPDFPageObjectTranslateAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength,
    float pageDeltaX,
    float pageDeltaY
) {
    PEObjectContext context = {0};
    if (!PEResolveObject(document, pageIndex, path, pathLength, &context)) {
        return false;
    }
    float determinant = context.parentMatrix.a * context.parentMatrix.d -
        context.parentMatrix.b * context.parentMatrix.c;
    if (determinant > -0.000001f && determinant < 0.000001f) {
        PECloseObjectContext(&context);
        return false;
    }
    float localDeltaX = (
        context.parentMatrix.d * pageDeltaX -
        context.parentMatrix.c * pageDeltaY
    ) / determinant;
    float localDeltaY = (
        -context.parentMatrix.b * pageDeltaX +
        context.parentMatrix.a * pageDeltaY
    ) / determinant;
    FS_MATRIX matrix = kPEIdentityMatrix;
    bool success = FPDFPageObj_GetMatrix(context.object, &matrix);
    if (success) {
        matrix.e += localDeltaX;
        matrix.f += localDeltaY;
        success = PECloneFormAncestorsForEditing(
            context.page, path, pathLength
        ) && FPDFPageObj_SetMatrix(context.object, &matrix) &&
            FPDFPage_GenerateContent(context.page);
    }
    PECloseObjectContext(&context);
    return success;
}

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
) {
    PEObjectContext context = {0};
    if (!PEResolveObject(document, pageIndex, path, pathLength, &context)) {
        return false;
    }
    FS_MATRIX inverseParent;
    FS_MATRIX requested = {pageA, pageB, pageC, pageD, pageE, pageF};
    FS_MATRIX local;
    bool success = PEMatrixInvert(context.parentMatrix, &inverseParent);
    if (success) {
        local = PEMatrixMultiply(inverseParent, requested);
        success = PECloneFormAncestorsForEditing(
            context.page, path, pathLength
        ) && FPDFPageObj_SetMatrix(context.object, &local) &&
            FPDFPage_GenerateContent(context.page);
    }
    PECloseObjectContext(&context);
    return success;
}

bool PEPDFPageObjectMoveToIndexAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength,
    int32_t destinationIndex
) {
    PEObjectContext context = {0};
    if (destinationIndex < 0 ||
        !PEResolveObject(document, pageIndex, path, pathLength, &context)) {
        return false;
    }
    bool success = PECloneFormAncestorsForEditing(
        context.page, path, pathLength
    );
    if (success) {
        success = pathLength == 1
            ? FPDFPage_MoveObject(
                context.page, (size_t)path[0], (size_t)destinationIndex
            )
            : context.parentForm != NULL && FPDFFormObj_MoveObject(
                context.parentForm,
                (size_t)path[pathLength - 1],
                (size_t)destinationIndex
            );
    }
    if (success) {
        success = FPDFPage_GenerateContent(context.page);
    }
    PECloseObjectContext(&context);
    return success;
}

bool PEPDFPageObjectDeleteAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength
) {
    PEObjectContext context = {0};
    if (!PEResolveObject(document, pageIndex, path, pathLength, &context)) {
        return false;
    }
    bool success = PECloneFormAncestorsForEditing(
        context.page, path, pathLength
    ) && (pathLength == 1
        ? FPDFPage_RemoveObject(context.page, context.object)
        : context.parentForm != NULL &&
            FPDFFormObj_RemoveObject(context.parentForm, context.object));
    if (success) {
        FPDFPageObj_Destroy(context.object);
        success = FPDFPage_GenerateContent(context.page);
    }
    PECloseObjectContext(&context);
    return success;
}

bool PEPDFPageObjectSetInvisibleAtPath(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const int32_t* path,
    size_t pathLength
) {
    PEObjectContext context = {0};
    if (!PEResolveObject(document, pageIndex, path, pathLength, &context) ||
        FPDFPageObj_GetType(context.object) != FPDF_PAGEOBJ_TEXT) {
        PECloseObjectContext(&context);
        return false;
    }
    bool success = PECloneFormAncestorsForEditing(
        context.page, path, pathLength
    ) && FPDFTextObj_SetTextRenderMode(
        context.object,
        FPDF_TEXTRENDERMODE_INVISIBLE
    ) && FPDFPage_GenerateContent(context.page);
    PECloseObjectContext(&context);
    return success;
}

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
) {
    FPDF_PAGE page = PELoadPage(document, pageIndex);
    if (page == NULL || fontName == NULL) {
        if (page != NULL) FPDF_ClosePage(page);
        return false;
    }
    FPDF_PAGEOBJECT object = FPDFPageObj_NewTextObj(
        document->handle,
        fontName,
        fontSize
    );
    uint16_t* terminatedText = PECopyWideString(text, textLength);
    FS_MATRIX matrix = {1, 0, 0, 1, x, y};
    bool success = object != NULL && terminatedText != NULL &&
        FPDFText_SetText(object, terminatedText) &&
        FPDFPageObj_SetFillColor(object, red, green, blue, alpha) &&
        FPDFPageObj_SetMatrix(object, &matrix) &&
        FPDFPage_InsertObject(page, object);
    free(terminatedText);
    if (success) {
        success = FPDFPage_GenerateContent(page);
    } else if (object != NULL) {
        FPDFPageObj_Destroy(object);
    }
    FPDF_ClosePage(page);
    return success;
}

bool PEPDFPageAddJPEG(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const uint8_t* jpegBytes,
    size_t jpegLength,
    float x,
    float y,
    float width,
    float height
) {
    FPDF_PAGE page = PELoadPage(document, pageIndex);
    if (page == NULL || jpegBytes == NULL || jpegLength == 0) {
        if (page != NULL) FPDF_ClosePage(page);
        return false;
    }
    PEReadBuffer readBuffer = {jpegBytes, jpegLength};
    FPDF_FILEACCESS access;
    access.m_FileLen = (unsigned long)jpegLength;
    access.m_GetBlock = PEReadBlock;
    access.m_Param = &readBuffer;
    FPDF_PAGEOBJECT object = FPDFPageObj_NewImageObj(document->handle);
    bool success = object != NULL &&
        FPDFImageObj_LoadJpegFileInline(NULL, 0, object, &access) &&
        FPDFImageObj_SetMatrix(object, width, 0, 0, height, x, y) &&
        FPDFPage_InsertObject(page, object);
    if (success) {
        success = FPDFPage_GenerateContent(page);
    } else if (object != NULL) {
        FPDFPageObj_Destroy(object);
    }
    FPDF_ClosePage(page);
    return success;
}

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
) {
    FPDF_PAGE page = PELoadPage(document, pageIndex);
    FPDF_BITMAP bitmap = PECreateBitmapBGRA(
        bitmapBytes, bitmapLength, pixelWidth, pixelHeight, bytesPerRow
    );
    if (page == NULL || bitmap == NULL || width <= 0 || height <= 0) {
        if (bitmap != NULL) FPDFBitmap_Destroy(bitmap);
        if (page != NULL) FPDF_ClosePage(page);
        return false;
    }
    FPDF_PAGEOBJECT object = FPDFPageObj_NewImageObj(document->handle);
    bool success = object != NULL &&
        FPDFImageObj_SetBitmap(&page, 1, object, bitmap) &&
        FPDFImageObj_SetMatrix(object, width, 0, 0, height, x, y) &&
        FPDFPage_InsertObject(page, object);
    FPDFBitmap_Destroy(bitmap);
    if (success) {
        success = FPDFPage_GenerateContent(page);
    } else if (object != NULL) {
        FPDFPageObj_Destroy(object);
    }
    FPDF_ClosePage(page);
    return success;
}

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
) {
    PEObjectContext context = {0};
    if (!PEResolveObject(document, pageIndex, path, pathLength, &context) ||
        FPDFPageObj_GetType(context.object) != FPDF_PAGEOBJ_IMAGE) {
        PECloseObjectContext(&context);
        return false;
    }
    FPDF_BITMAP bitmap = PECreateBitmapBGRA(
        bitmapBytes, bitmapLength, pixelWidth, pixelHeight, bytesPerRow
    );
    bool success = bitmap != NULL && PECloneFormAncestorsForEditing(
        context.page, path, pathLength
    ) && FPDFImageObj_SetBitmapIsolated(
        &context.page, 1, context.object, bitmap
    ) && FPDFPage_GenerateContent(context.page);
    if (bitmap != NULL) FPDFBitmap_Destroy(bitmap);
    PECloseObjectContext(&context);
    return success;
}

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
) {
    if (outputBytes == NULL || outputLength == NULL || outputWidth == NULL ||
        outputHeight == NULL || outputStride == NULL || outputFormat == NULL) {
        return false;
    }
    *outputBytes = NULL;
    *outputLength = 0;
    PEObjectContext context = {0};
    if (!PEResolveObject(document, pageIndex, path, pathLength, &context) ||
        FPDFPageObj_GetType(context.object) != FPDF_PAGEOBJ_IMAGE) {
        PECloseObjectContext(&context);
        return false;
    }
    FPDF_BITMAP bitmap = FPDFImageObj_GetRenderedBitmap(
        document->handle, context.page, context.object
    );
    int width = bitmap == NULL ? 0 : FPDFBitmap_GetWidth(bitmap);
    int height = bitmap == NULL ? 0 : FPDFBitmap_GetHeight(bitmap);
    int stride = bitmap == NULL ? 0 : FPDFBitmap_GetStride(bitmap);
    void* source = bitmap == NULL ? NULL : FPDFBitmap_GetBuffer(bitmap);
    bool dimensionsValid = width > 0 && height > 0 && stride > 0 &&
        (size_t)stride <= SIZE_MAX / (size_t)height;
    size_t length = dimensionsValid ? (size_t)stride * (size_t)height : 0;
    uint8_t* copied = source != NULL && length > 0
        ? (uint8_t*)malloc(length)
        : NULL;
    bool success = copied != NULL;
    if (success) {
        memcpy(copied, source, length);
        *outputBytes = copied;
        *outputLength = length;
        *outputWidth = width;
        *outputHeight = height;
        *outputStride = stride;
        *outputFormat = FPDFBitmap_GetFormat(bitmap);
    }
    if (bitmap != NULL) FPDFBitmap_Destroy(bitmap);
    PECloseObjectContext(&context);
    return success;
}

static bool PEAddActualTextMark(
    FPDF_DOCUMENT document,
    FPDF_PAGEOBJECT object,
    const uint16_t* text,
    size_t textLength
) {
    size_t byteLength = 2 + textLength * 2;
    uint8_t* bytes = (uint8_t*)malloc(byteLength);
    if (bytes == NULL) {
        return false;
    }
    bytes[0] = 0xFE;
    bytes[1] = 0xFF;
    for (size_t index = 0; index < textLength; ++index) {
        bytes[2 + index * 2] = (uint8_t)(text[index] >> 8);
        bytes[3 + index * 2] = (uint8_t)(text[index] & 0xFF);
    }
    FPDF_PAGEOBJECTMARK mark = FPDFPageObj_AddMark(object, "Span");
    bool success = mark != NULL && FPDFPageObjMark_SetBlobParam(
        document,
        object,
        mark,
        "ActualText",
        bytes,
        (unsigned long)byteLength
    );
    free(bytes);
    return success;
}

static bool PEApplyActualTextToOverlayObjects(
    FPDF_DOCUMENT document,
    FPDF_PAGEOBJECT object,
    const uint16_t* actualText,
    size_t actualTextLength,
    bool* assigned
) {
    int type = FPDFPageObj_GetType(object);
    if (type == FPDF_PAGEOBJ_TEXT) {
        bool success = *assigned
            ? FPDFPageObj_AddMark(object, "Artifact") != NULL
            : PEAddActualTextMark(
                document,
                object,
                actualText,
                actualTextLength
            );
        *assigned = true;
        return success;
    }
    if (type != FPDF_PAGEOBJ_FORM) {
        return true;
    }

    bool hadText = *assigned;
    int count = FPDFFormObj_CountObjects(object);
    for (int index = 0; index < count; ++index) {
        FPDF_PAGEOBJECT child = FPDFFormObj_GetObject(
            object,
            (unsigned long)index
        );
        if (child == NULL || !PEApplyActualTextToOverlayObjects(
            document,
            child,
            actualText,
            actualTextLength,
            assigned
        )) {
            return false;
        }
    }
    return *assigned == hadText || FPDFFormObj_CloneForEditing(object);
}

static bool PEImportOverlay(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const uint8_t* overlayPDFBytes,
    size_t overlayPDFLength,
    const uint16_t* actualText,
    size_t actualTextLength
) {
    if (document == NULL || document->handle == NULL ||
        overlayPDFBytes == NULL || overlayPDFLength == 0) {
        return false;
    }
    FPDF_PAGE page = PELoadPage(document, pageIndex);
    if (page == NULL) {
        return false;
    }
    FPDF_DOCUMENT overlayDocument = FPDF_LoadMemDocument64(
        overlayPDFBytes,
        overlayPDFLength,
        NULL
    );
    if (overlayDocument == NULL) {
        FPDF_ClosePage(page);
        return false;
    }
    FPDF_XOBJECT xobject = FPDF_NewXObjectFromPage(
        document->handle,
        overlayDocument,
        0
    );
    FPDF_PAGEOBJECT formObject = xobject != NULL
        ? FPDF_NewFormObjectFromXObject(xobject)
        : NULL;
    bool success = formObject != NULL;
    if (success && actualText != NULL && actualTextLength > 0) {
        bool assigned = false;
        success = PEApplyActualTextToOverlayObjects(
            document->handle,
            formObject,
            actualText,
            actualTextLength,
            &assigned
        ) && assigned;
    }
    success = success &&
        FPDFPage_InsertObject(page, formObject) &&
        FPDFPage_GenerateContent(page);
    if (!success && formObject != NULL) {
        FPDFPageObj_Destroy(formObject);
    }
    if (xobject != NULL) {
        FPDF_CloseXObject(xobject);
    }
    FPDF_CloseDocument(overlayDocument);
    FPDF_ClosePage(page);
    return success;
}

bool PEPDFPageImportOverlay(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const uint8_t* overlayPDFBytes,
    size_t overlayPDFLength
) {
    return PEImportOverlay(
        document,
        pageIndex,
        overlayPDFBytes,
        overlayPDFLength,
        NULL,
        0
    );
}

bool PEPDFPageImportOverlayWithActualText(
    PEPDFDocumentRef document,
    int32_t pageIndex,
    const uint8_t* overlayPDFBytes,
    size_t overlayPDFLength,
    const uint16_t* actualText,
    size_t actualTextLength
) {
    return PEImportOverlay(
        document,
        pageIndex,
        overlayPDFBytes,
        overlayPDFLength,
        actualText,
        actualTextLength
    );
}

PEPDFFontRef PEPDFFontCreateEmbedded(
    PEPDFDocumentRef document,
    const uint8_t* fontBytes,
    size_t fontLength
) {
    if (document == NULL || document->handle == NULL || fontBytes == NULL ||
        fontLength == 0 || fontLength > UINT32_MAX) {
        return NULL;
    }
    PEPDFFontRef font = (PEPDFFontRef)calloc(1, sizeof(struct PEPDFFont));
    if (font == NULL) {
        return NULL;
    }
    int fontType = fontLength >= 4 &&
        fontBytes[0] == 'O' && fontBytes[1] == 'T' &&
        fontBytes[2] == 'T' && fontBytes[3] == 'O'
        ? FPDF_FONT_TYPE1
        : FPDF_FONT_TRUETYPE;
    font->handle = FPDFText_LoadFont(
        document->handle,
        fontBytes,
        (uint32_t)fontLength,
        fontType,
        true
    );
    if (font->handle == NULL) {
        free(font);
        return NULL;
    }
    return font;
}

void PEPDFFontClose(PEPDFFontRef font) {
    if (font == NULL) {
        return;
    }
    if (font->handle != NULL) {
        FPDFFont_Close(font->handle);
    }
    free(font);
}

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
) {
    if (document == NULL || document->handle == NULL || font == NULL ||
        font->handle == NULL || fontSize <= 0) {
        return false;
    }
    FPDF_PAGE page = PELoadPage(document, pageIndex);
    if (page == NULL) {
        return false;
    }
    FPDF_PAGEOBJECT object = FPDFPageObj_CreateTextObj(
        document->handle,
        font->handle,
        fontSize
    );
    uint16_t* terminatedText = PECopyWideString(text, textLength);
    bool success = object != NULL && terminatedText != NULL &&
        FPDFText_SetText(object, terminatedText);
    free(terminatedText);
    if (success && invisible) {
        success = FPDFTextObj_SetTextRenderMode(
            object,
            FPDF_TEXTRENDERMODE_INVISIBLE
        );
    }
    if (success) {
        FPDFPageObj_Transform(object, 1, 0, 0, 1, x, y);
        FPDFPage_InsertObject(page, object);
        success = FPDFPage_GenerateContent(page);
    }
    if (!success && object != NULL) {
        FPDFPageObj_Destroy(object);
    }
    FPDF_ClosePage(page);
    return success;
}

void PEPDFFree(void* pointer) {
    free(pointer);
}
