/**
 * @description     Public webhook that MuleSoft IDP calls when an execution finishes (callback.noAuthUrl). It is a
 *                  signal only: it verifies the HMAC signature, matches the stage row by its random token and
 *                  publishes DNAMSIDPEvent__e (Callback); the GET of the result runs later as the integration user.
 *                  Endpoint: <IDPCallbackSiteURL__c>/services/apexrest/v1/receiveIdpCallback?t=..&a=..&av=..&sig=..
 *                  Documented exceptions to the CK guidelines:
 *                  - "No Webhooks via Site classes": exposed through the dedicated Site DNAMSIDPCallback because
 *                    MuleSoft IDP only supports an unauthenticated callback URL (architecture decision, Lucid LLD page 5).
 *                    This is the only guest-exposed class; it never accepts or returns Salesforce Ids (random token).
 *                  - "CLS Integration Framework": not installed in this org, so the framework is not used.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
// Exception to guideline: without sharing because the guest Site user owns no pipeline records and must find the
// stage row by its token; access is gated by the HMAC signature, checked before any record is read.
@RestResource(urlMapping='/v1/receiveIdpCallback/*')
global without sharing class DNAMSIDPCallbackAPI {
    private static final String CLASS_NAME = 'DNAMSIDPCallbackAPI';
    private static final String STATUS_ACCEPTED = 'accepted';
    private static final String STATUS_IGNORED = 'ignored';
    private static final String STATUS_REJECTED = 'rejected';
    private static final String STATUS_ERROR = 'error';
    private static final String PATH_MARKER = '/v1/receiveIdpCallback/';
    private static final String MASK = '***';
    private static final Integer TRACE_LENGTH = 32768;
    private static final Integer BODY_PREVIEW_LENGTH = 4000;
    private static final Set<String> SECRET_HEADERS = new Set<String>{ 'authorization', 'cookie', 'proxy-authorization' };

    /**
     * @description POST callback entry point.
     **/
    @HttpPost
    global static void receiveCallbackPost() {
        handleCallback(RestContext.request, RestContext.response);
    }

    /**
     * @description GET callback entry point (the IDP callback method is undocumented, so every method is accepted).
     **/
    @HttpGet
    global static void receiveCallbackGet() {
        handleCallback(RestContext.request, RestContext.response);
    }

    /**
     * @description PATCH callback entry point. IDP calls the callback with PATCH (community-documented); without this
     *              entry point Salesforce answers 405 before any Apex runs and the callback is lost (IDP does not retry).
     **/
    @HttpPatch
    global static void receiveCallbackPatch() {
        handleCallback(RestContext.request, RestContext.response);
    }

    /**
     * @description PUT callback entry point, accepted for the same reason as PATCH.
     **/
    @HttpPut
    global static void receiveCallbackPut() {
        handleCallback(RestContext.request, RestContext.response);
    }

    /**
     * @description Verifies, matches and hands the callback off to the pipeline. Every attempt is recorded: accepted
     *              ones on the row (CallbackPayload__c), refused or ignored ones as a Callback Rejected error log.
     * @param request  REST request (path /t/a/av/sig, or the older query parameters t, a, av, sig)
     * @param response REST response
     **/
    private static void handleCallback(RestRequest request, RestResponse response) {
        Map<String, String> params = readParams(request);
        String signature = params.remove(DNAMSPipelineConstants.PARAM_SIGNATURE);
        String trace = describeRequest(request);
        if (!DNAMSCallbackSignatureUtil.isValidSignature(params, signature)) {
            recordRejection(null, 'Signature missing or invalid (HTTP 401).', trace);
            respond(response, 401, STATUS_REJECTED);
            return;
        }
        AIReviewStageResult__c row = findRow(params.get(DNAMSPipelineConstants.PARAM_TOKEN));
        if (row == null || !isMatchingAction(row, params)) {
            recordRejection(row, 'Unknown token or action mismatch (HTTP 400).', trace);
            respond(response, 400, STATUS_REJECTED);
            return;
        }
        if (row.ProcessingStatus__c != DNAMSPipelineConstants.ROW_IN_PROGRESS) {
            recordRejection(row, 'Row is ' + row.ProcessingStatus__c + '; duplicate or late callback ignored (HTTP 200).', trace);
            respond(response, 200, STATUS_IGNORED);
            return;
        }
        acceptCallback(row, trace, response);
    }

    /**
     * @description Reads t, a, av and sig from the path (/receiveIdpCallback/t/a/av/sig), falling back to the query
     *              string used by earlier callback URLs.
     * @param request REST request
     * @return        Parameters keyed t, a, av, sig (values may be null)
     **/
    private static Map<String, String> readParams(RestRequest request) {
        Map<String, String> params = new Map<String, String>();
        List<String> keys = new List<String>(DNAMSPipelineConstants.PATH_PARAM_ORDER);
        keys.add(DNAMSPipelineConstants.PARAM_SIGNATURE);
        String tail = (request.requestURI ?? '').substringAfter(PATH_MARKER).removeEnd('/');
        List<String> segments = String.isBlank(tail) ? new List<String>() : tail.split('/');
        Boolean isPathForm = segments.size() == keys.size();
        for (Integer index = 0; index < keys.size(); index++) {
            String value = isPathForm ? EncodingUtil.urlDecode(segments[index], 'UTF-8') : request.params.get(keys[index]);
            params.put(keys[index], value);
        }
        return params;
    }

    /**
     * @description Stage row for a callback token.
     * @param token Callback token (may be blank)
     * @return      The row, or null
     **/
    private static AIReviewStageResult__c findRow(String token) {
        if (String.isBlank(token)) {
            return null;
        }
        List<AIReviewStageResult__c> rows = [
            SELECT Id, ReviewRun__c, PackageElement__c, IDPActionId__c, IDPActionVersion__c, ProcessingStatus__c
            FROM AIReviewStageResult__c
            WHERE CallbackToken__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * @description What the caller sent: method, path (signature masked), parameters, headers (no auth/cookies) and
     *              the start of the body. Contains no Salesforce record data.
     * @param request REST request
     * @return        Text for CallbackPayload__c / RawPayload__c
     **/
    private static String describeRequest(RestRequest request) {
        List<String> lines = new List<String>{ request.httpMethod + ' ' + maskSignature(request.requestURI) };
        for (String key : request.params.keySet()) {
            lines.add('param ' + key + '=' + (key == DNAMSPipelineConstants.PARAM_SIGNATURE ? MASK : request.params.get(key)));
        }
        for (String key : request.headers.keySet()) {
            if (!SECRET_HEADERS.contains(key.toLowerCase())) {
                lines.add('header ' + key + ': ' + request.headers.get(key));
            }
        }
        lines.add('body ' + readBody(request));
        return String.join(lines, '\n').left(TRACE_LENGTH);
    }

    /**
     * @description Start of the request body as text.
     * @param request REST request
     * @return        Body preview, empty, or a note when it is not text
     **/
    private static String readBody(RestRequest request) {
        try {
            return (request.requestBody?.toString() ?? '').left(BODY_PREVIEW_LENGTH);
        } catch (Exception bodyError) {
            // Handled: a binary body is only described, never stored
            return '<non-text body, ' + request.requestBody.size() + ' bytes>';
        }
    }

    /**
     * @description Masks the signature segment of a path-form callback URI.
     * @param uri Request URI
     * @return    URI with the last segment replaced when it is the path form
     **/
    private static String maskSignature(String uri) {
        if (String.isBlank(uri) || uri.substringAfter(PATH_MARKER).split('/').size() != DNAMSPipelineConstants.PATH_PARAM_ORDER.size() + 1) {
            return uri;
        }
        return uri.substringBeforeLast('/') + '/' + MASK;
    }

    /**
     * @description Records a refused or ignored callback; never blocks the response.
     * @param row    Matched stage row, or null
     * @param reason Why it was refused or ignored
     * @param trace  Request description
     **/
    private static void recordRejection(AIReviewStageResult__c row, String reason, String trace) {
        DNAMSErrorLogHelper.LogDetail detail = new DNAMSErrorLogHelper.LogDetail();
        detail.runId = row?.ReviewRun__c;
        detail.elementId = row?.PackageElement__c;
        detail.stageResultId = row?.Id;
        detail.errorType = DNAMSPipelineConstants.ERROR_CALLBACK_REJECTED;
        detail.severity = DNAMSPipelineConstants.SEVERITY_WARNING;
        detail.sourceClass = CLASS_NAME;
        detail.message = reason;
        detail.rawPayload = trace;
        DNAMSErrorLogHelper.insertLogs(new List<AIReviewErrorLog__c>{ DNAMSErrorLogHelper.buildLog(detail) });
    }

    /**
     * @description Stamps the row (received time and request details) and publishes the Callback event.
     * @param row      Matched stage row (In Progress)
     * @param trace    Request description
     * @param response REST response
     **/
    private static void acceptCallback(AIReviewStageResult__c row, String trace, RestResponse response) {
        try {
            row.CallbackReceivedAt__c = System.now();
            row.CallbackPayload__c = trace;
            update as system row;
            // Hand-off to DNAMSIDPEventTrigger, which runs as the IDP integration user
            Database.SaveResult result = EventBus.publish(new DNAMSIDPEvent__e(
                EventType__c = DNAMSPipelineConstants.EVENT_CALLBACK,
                ReviewRunId__c = row.ReviewRun__c,
                StageResultId__c = row.Id
            ));
            if (!result.isSuccess()) {
                throw new DNAMSPipelineException('DNAMSIDPEvent__e publish failed: ' + result.getErrors()[0].getMessage());
            }
            respond(response, 200, STATUS_ACCEPTED);
        } catch (Exception publishError) {
            DNAMSErrorLogHelper.logException(publishError, row.ReviewRun__c, CLASS_NAME);
            respond(response, 417, STATUS_ERROR);
        }
    }

    /**
     * @description True when the callback's action id and version match the row.
     * @param row    Stage row
     * @param params Received parameters
     * @return       True on match
     **/
    private static Boolean isMatchingAction(AIReviewStageResult__c row, Map<String, String> params) {
        return row.IDPActionId__c == params.get(DNAMSPipelineConstants.PARAM_ACTION_ID)
            && row.IDPActionVersion__c == params.get(DNAMSPipelineConstants.PARAM_ACTION_VERSION);
    }

    /**
     * @description Writes a lowerCamel JSON response {"status": ..}. No record data is ever returned.
     * @param response   REST response
     * @param statusCode HTTP status
     * @param status     Outcome keyword (accepted, ignored, rejected, error)
     **/
    private static void respond(RestResponse response, Integer statusCode, String status) {
        response.statusCode = statusCode;
        response.addHeader('Content-Type', 'application/json');
        response.responseBody = Blob.valueOf(JSON.serialize(new Map<String, String>{ 'status' => status }));
    }
}
