/* compat/openssl/sha.h -- iOS shim: the only OpenSSL call OpenUG2 makes is SHA256()
 * (src/ugui/ugui_glyph_folder.c), so on iOS it is served by Apple's CommonCrypto
 * instead of building and linking libcrypto. Put ios/compat on the header search
 * path BEFORE any system include path. */
#ifndef OPENUG2_IOS_COMPAT_OPENSSL_SHA_H
#define OPENUG2_IOS_COMPAT_OPENSSL_SHA_H

#include <CommonCrypto/CommonDigest.h>
#include <stddef.h>
#include <stdint.h>

#define SHA256_DIGEST_LENGTH CC_SHA256_DIGEST_LENGTH

/* Same contract as OpenSSL's: writes 32 bytes to md and returns md, or NULL on failure. */
static inline unsigned char *SHA256(const unsigned char *d, size_t n, unsigned char *md) {
    if (!md || (!d && n) || n > (size_t)UINT32_MAX) return NULL;   /* CC_LONG is 32 bit */
    CC_SHA256(d, (CC_LONG)n, md);
    return md;
}

#endif
