/**
 * @description     Signs and verifies the IDP callback URL parameters (HMAC-SHA256, Base64-URL without padding) and
 *                  generates the random callback token that stands in for Salesforce Ids on the public callback.
 *                  Key: protected custom setting DNAMSIDPSecret__c.SigningKey__c (org default).
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
public inherited sharing class DNAMSCallbackSignatureUtil {
    private static final String HMAC_ALGORITHM = 'hmacSHA256';
    // 32-byte HMAC-SHA256 = 43 Base64-URL characters without padding
    private static final Pattern SIGNATURE_PATTERN = Pattern.compile('^[A-Za-z0-9_-]{43}$');

    /**
     * @description Random callback token.
     * @return      32 hex characters (128 random bits)
     **/
    public static String generateToken() {
        return EncodingUtil.convertToHex(Crypto.generateAesKey(128));
    }

    /**
     * @description Signs the parameters. Canonical form: keys sorted, joined as k=v&k=v (null values as empty).
     * @param params Parameters to sign (without sig)
     * @return       Base64-URL HMAC-SHA256 without padding
     * @throws DNAMSPipelineException when DNAMSIDPSecret__c.SigningKey__c is blank
     **/
    public static String sign(Map<String, String> params) {
        String signingKey = DNAMSIDPSecret__c.getOrgDefaults().SigningKey__c;
        if (String.isBlank(signingKey)) {
            throw new DNAMSPipelineException('DNAMSIDPSecret__c.SigningKey__c is not set.');
        }
        Blob mac = Crypto.generateMac(HMAC_ALGORITHM, Blob.valueOf(toCanonical(params)), Blob.valueOf(signingKey));
        return EncodingUtil.base64Encode(mac).replace('+', '-').replace('/', '_').replace('=', '');
    }

    /**
     * @description Verifies a signature in constant time (Crypto.verifyHMac). Returns false, never throws, for a
     *              missing or malformed signature or a missing signing key.
     * @param params    Received parameters (without sig)
     * @param signature Received sig value
     * @return          True when the signature matches
     **/
    public static Boolean isValidSignature(Map<String, String> params, String signature) {
        String signingKey = DNAMSIDPSecret__c.getOrgDefaults().SigningKey__c;
        if (params == null || String.isBlank(signingKey) || signature == null || !SIGNATURE_PATTERN.matcher(signature).matches()) {
            return false;
        }
        Blob mac = EncodingUtil.base64Decode(signature.replace('-', '+').replace('_', '/') + '=');
        return Crypto.verifyHMac(HMAC_ALGORITHM, Blob.valueOf(toCanonical(params)), Blob.valueOf(signingKey), mac);
    }

    /**
     * @description Callback URL with everything in the path, so it survives a caller that drops the query string:
     *              base + CALLBACK_PATH + '/' + token + '/' + action id + '/' + action version + '/' + signature.
     * @param baseUrl Callback Site base URL (DNAMS_Pipeline_Setting__mdt.IDPCallbackSiteURL__c)
     * @param params  Parameters to sign and send (t, a, av)
     * @return        Signed callback URL
     **/
    public static String buildCallbackUrl(String baseUrl, Map<String, String> params) {
        List<String> segments = new List<String>();
        for (String key : DNAMSPipelineConstants.PATH_PARAM_ORDER) {
            segments.add(EncodingUtil.urlEncode(params.get(key) ?? '', 'UTF-8'));
        }
        segments.add(EncodingUtil.urlEncode(sign(params), 'UTF-8'));
        return (baseUrl ?? '').removeEnd('/') + DNAMSPipelineConstants.CALLBACK_PATH + '/' + String.join(segments, '/');
    }

    /**
     * @description Canonical string that is signed.
     * @param params Parameters
     * @return       k=v&k=v with keys sorted
     **/
    private static String toCanonical(Map<String, String> params) {
        List<String> pairs = new List<String>();
        for (String key : sortedKeys(params)) {
            pairs.add(key + '=' + (params.get(key) ?? ''));
        }
        return String.join(pairs, '&');
    }

    /**
     * @description Sorted parameter names.
     * @param params Parameters
     * @return       Sorted keys
     **/
    private static List<String> sortedKeys(Map<String, String> params) {
        List<String> keys = new List<String>(params.keySet());
        keys.sort();
        return keys;
    }
}
