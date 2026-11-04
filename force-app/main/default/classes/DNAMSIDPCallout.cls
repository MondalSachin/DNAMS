/**
 * @description     Live MuleSoft IDP client. POSTs a document as multipart/form-data (parts "file" and "callback")
 *                  and GETs the execution result. No DML here, so callers can run several callouts before their DML.
 *                  Integration: MuleSoft Intelligent Document Processing (IDP) executions API.
 *                  Named Credential: DNAMSMuleSoftIDP (External Credential DNAMSMuleSoftIDP, OAuth client credentials),
 *                  name read from DNAMS_Pipeline_Setting__mdt.IDPNamedCredential__c.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
public inherited sharing class DNAMSIDPCallout implements IDocumentExtractionClient {
    private static final Integer TIMEOUT_MS = 120000;
    private static final String BOUNDARY = 'DNAMSIDPBoundary7f3c9a1e5b2d4c6e8a0f';
    private static final String CRLF = '\r\n';
    private static final String EXECUTION_ID_PLACEHOLDER = '{executionId}';

    /**
     * @description POSTs the file and the callback URL to the action's PostPath. Any failure (non-2xx, unparseable
     *              body, missing id, callout exception) is returned as isSuccess = false; the caller logs it after
     *              its callouts, because a log insert here would block the next callout in the same transaction.
     * @param request Action, file name, file body and callback URL
     * @return        POST outcome
     **/
    public DNAMSIDPWrapper.SubmitResult submitDocument(DNAMSIDPWrapper.SubmitRequest request) {
        DNAMSIDPWrapper.SubmitResult result = new DNAMSIDPWrapper.SubmitResult();
        result.isSuccess = false;
        try {
            HttpRequest httpRequest = buildRequest('POST', request.action.postPath);
            httpRequest.setHeader('Content-Type', 'multipart/form-data; boundary=' + BOUNDARY);
            httpRequest.setBodyAsBlob(buildMultipartBody(request));
            // Callout to MuleSoft IDP: create execution
            HttpResponse response = new Http().send(httpRequest);
            result.statusCode = response.getStatusCode();
            result.responseBody = response.getBody();
            if (!isOk(result.statusCode)) {
                result.errorMessage = 'IDP POST returned HTTP ' + result.statusCode;
                return result;
            }
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(result.responseBody);
            result.executionId = (String) (body.get('id') ?? body.get('executionId'));
            result.executionStatus = (String) body.get('status');
            result.isSuccess = String.isNotBlank(result.executionId);
            result.errorMessage = result.isSuccess ? null : 'IDP POST response has no execution id';
        } catch (Exception e) {
            // Handled: converted to a failed result that the caller records as a POST Error log
            result.errorMessage = e.getTypeName() + ': ' + e.getMessage();
        }
        return result;
    }

    /**
     * @description GETs one execution from the action's GetPath. Failures come back as isSuccess = false.
     * @param action      IDP action
     * @param executionId MuleSoft execution id
     * @return            GET outcome with the raw body
     **/
    public DNAMSIDPWrapper.ExecutionResult fetchExecution(DNAMSIDPWrapper.ActionConfig action, String executionId) {
        DNAMSIDPWrapper.ExecutionResult result = new DNAMSIDPWrapper.ExecutionResult();
        result.isSuccess = false;
        try {
            String path = action.getPath.replace(EXECUTION_ID_PLACEHOLDER, EncodingUtil.urlEncode(executionId, 'UTF-8'));
            // Callout to MuleSoft IDP: read execution result
            HttpResponse response = new Http().send(buildRequest('GET', path));
            result.statusCode = response.getStatusCode();
            result.responseBody = response.getBody();
            if (!isOk(result.statusCode)) {
                result.errorMessage = 'IDP GET returned HTTP ' + result.statusCode;
                return result;
            }
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(result.responseBody);
            result.executionStatus = (String) body.get('status');
            result.isSuccess = true;
        } catch (Exception e) {
            // Handled: converted to a failed result that the caller records as an IDP Failure log
            result.errorMessage = e.getTypeName() + ': ' + e.getMessage();
        }
        return result;
    }

    /**
     * @description Request with the Named Credential endpoint and the 120 s timeout.
     * @param method HTTP method
     * @param path   Path below the Named Credential base URL
     * @return       Prepared request
     **/
    private static HttpRequest buildRequest(String method, String path) {
        HttpRequest httpRequest = new HttpRequest();
        httpRequest.setMethod(method);
        httpRequest.setEndpoint('callout:' + DNAMS_PackageReviewPipelineService.settings().IDPNamedCredential__c + path);
        httpRequest.setTimeout(TIMEOUT_MS);
        return httpRequest;
    }

    /**
     * @description Builds the multipart body as a Blob. Apex cannot concatenate binary Blobs, so the parts are joined
     *              as base64: the text head is padded to a multiple of 3 bytes, and the file's base64 padding is
     *              replaced with the bits of the CRLF (or CR) that must follow the file anyway.
     * @param request Submit request (file name, body, callback URL)
     * @return        Multipart body: part "callback" (text/plain JSON) then part "file" (binary)
     **/
    @TestVisible
    private static Blob buildMultipartBody(DNAMSIDPWrapper.SubmitRequest request) {
        String fileName = (request.fileName ?? 'document.pdf').replaceAll('[\\r\\n"]', '');
        String fileType = fileName.toLowerCase().endsWith('.pdf') ? 'application/pdf' : 'application/octet-stream';
        String head = '--' + BOUNDARY + CRLF
            + 'Content-Disposition: form-data; name="callback"' + CRLF
            + 'Content-Type: text/plain' + CRLF + CRLF
            + JSON.serialize(new Map<String, String>{ 'noAuthUrl' => request.callbackUrl }) + CRLF
            + '--' + BOUNDARY + CRLF
            + 'Content-Disposition: form-data; name="file"; filename="' + fileName + '"' + CRLF
            + 'Content-Type: ' + fileType;
        // Trailing spaces in the header value keep the head base64 free of '=' padding
        while (Math.mod(Blob.valueOf(head + CRLF + CRLF).size(), 3) != 0) {
            head += ' ';
        }
        // Memory: every copy of the file is released as soon as the next one exists, so the peak stays near
        // 2.7x the file size and a 3 MB file fits the 12 MB async heap (the request no longer holds the file).
        String fileEncoded = EncodingUtil.base64Encode(request.fileBody ?? Blob.valueOf(''));
        request.fileBody = null;
        String footer = '--' + BOUNDARY + '--';
        Integer paddingCut = 0;
        String paddingPatch = '';
        if (fileEncoded.endsWith('==')) {
            // 'XY==' -> 'XY0K' encodes the last byte followed by CR LF
            paddingCut = 2;
            paddingPatch = '0K';
        } else if (fileEncoded.endsWith('=')) {
            // 'XYZ=' -> 'XYZN' encodes the last two bytes followed by CR
            paddingCut = 1;
            paddingPatch = 'N';
            footer = '\n' + footer;
        } else {
            footer = CRLF + footer;
        }
        String bodyEncoded = EncodingUtil.base64Encode(Blob.valueOf(head + CRLF + CRLF))
            + (paddingCut == 0 ? fileEncoded : fileEncoded.left(fileEncoded.length() - paddingCut))
            + paddingPatch
            + EncodingUtil.base64Encode(Blob.valueOf(footer));
        fileEncoded = null;
        return EncodingUtil.base64Decode(bodyEncoded);
    }

    /**
     * @description HTTP 2xx check (IDP answers 200 or 201).
     * @param statusCode HTTP status code
     * @return           True for 2xx
     **/
    private static Boolean isOk(Integer statusCode) {
        return statusCode >= 200 && statusCode < 300;
    }
}
