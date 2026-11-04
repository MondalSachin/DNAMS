/**
 * @description     Unit tests for DNAMSIDPCallbackAPI (signature, token match, duplicates, hand-off).
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
@IsTest
private class DNAMSIDPCallbackAPITest {
    private static final String TOKEN_IN_PROGRESS = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
    private static final String TOKEN_COMPLETED = 'f0e1d2c3b4a5968778695a4b3c2d1e0f';
    private static final String ACTION_ID = 'a79ee2e9-4bde-4f04-9ec4-4ba4844dc39c';
    private static final String ACTION_VERSION = '1.0.0';

    /**
     * @description Extraction fixture plus one In Progress and one Completed stage row.
     **/
    @TestSetup
    static void setupData() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            if (DNAMSIDPSecret__c.getOrgDefaults().Id == null) {
                insert new DNAMSIDPSecret__c(SetupOwnerId = UserInfo.getOrganizationId(), SigningKey__c = 'test-key');
            }
            insert new List<AIReviewStageResult__c>{
                buildRow(fixture, TOKEN_IN_PROGRESS, DNAMSPipelineConstants.ROW_IN_PROGRESS),
                buildRow(fixture, TOKEN_COMPLETED, DNAMSPipelineConstants.ROW_COMPLETED)
            };
        }
    }

    /**
     * @description Stage row for the Dealer Application element.
     * @param fixture Pipeline fixture
     * @param token   Callback token
     * @param status  Processing status
     * @return        Unsaved row
     **/
    private static AIReviewStageResult__c buildRow(DNAMSPipelineTestHelper.PipelineFixture fixture, String token, String status) {
        return new AIReviewStageResult__c(
            ReviewRun__c = fixture.runId,
            PackageElement__c = fixture.elementIdByType?.get('Dealer Application'),
            Stage__c = DNAMSPipelineConstants.STAGE_EXTRACTION,
            DocumentType__c = 'Dealer Application',
            IDPActionName__c = 'DealerApplication',
            IDPActionId__c = ACTION_ID,
            IDPActionVersion__c = ACTION_VERSION,
            CallbackToken__c = token,
            MuleSoftExecutionId__c = 'exec-' + token.left(8),
            ProcessingStatus__c = status
        );
    }

    /**
     * @description Sets RestContext with signed (or overridden) parameters.
     * @param token      t value
     * @param actionId   a value
     * @param signature  sig value; null signs t/a/av correctly
     **/
    private static void setRequest(String token, String actionId, String signature) {
        Map<String, String> params = new Map<String, String>{
            DNAMSPipelineConstants.PARAM_TOKEN => token,
            DNAMSPipelineConstants.PARAM_ACTION_ID => actionId,
            DNAMSPipelineConstants.PARAM_ACTION_VERSION => ACTION_VERSION
        };
        RestRequest request = new RestRequest();
        request.requestURI = DNAMSPipelineConstants.CALLBACK_PATH;
        for (String key : params.keySet()) {
            request.addParameter(key, params.get(key));
        }
        request.addParameter(DNAMSPipelineConstants.PARAM_SIGNATURE, signature ?? DNAMSCallbackSignatureUtil.sign(params));
        RestContext.request = request;
        RestContext.response = new RestResponse();
    }

    /**
     * @description Response status keyword.
     * @return      Value of "status" in the JSON body
     **/
    private static String getResponseStatus() {
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        return (String) body.get('status');
    }

    /**
     * @description Stage row by token.
     * @param token Callback token
     * @return      Row with CallbackReceivedAt__c
     **/
    private static AIReviewStageResult__c getRow(String token) {
        return [SELECT Id, CallbackReceivedAt__c FROM AIReviewStageResult__c WHERE CallbackToken__c = :token LIMIT 1];
    }

    /**
     * @description Valid callback for an In Progress row: 200 accepted and the row is stamped.
     **/
    @IsTest
    static void testValidCallbackAccepted() {
        DNAMSIDPActionUtil.clientOverride = new DNAMSIDPStubCallout();
        DNAMSIDPStubCallout.stubBodyOverride = '{"TradeName":"Acme"}';
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            setRequest(TOKEN_IN_PROGRESS, ACTION_ID, null);
            Test.startTest();
            DNAMSIDPCallbackAPI.receiveCallbackPost();
            Test.stopTest();
            Assert.areEqual(200, RestContext.response.statusCode, 'Accepted with 200');
            Assert.areEqual('accepted', getResponseStatus(), 'Status accepted');
            Assert.isNotNull(getRow(TOKEN_IN_PROGRESS).CallbackReceivedAt__c, 'Callback time stamped');
        }
    }

    /**
     * @description Duplicate callback (row no longer In Progress) via GET: 200 ignored, row untouched.
     **/
    @IsTest
    static void testDuplicateCallbackIgnored() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            setRequest(TOKEN_COMPLETED, ACTION_ID, null);
            Test.startTest();
            DNAMSIDPCallbackAPI.receiveCallbackGet();
            Test.stopTest();
            Assert.areEqual(200, RestContext.response.statusCode, 'Duplicate is 200');
            Assert.areEqual('ignored', getResponseStatus(), 'Status ignored');
            Assert.isNull(getRow(TOKEN_COMPLETED).CallbackReceivedAt__c, 'Row untouched');
        }
    }

    /**
     * @description Invalid and missing signatures: 401, row untouched.
     **/
    @IsTest
    static void testInvalidSignatureRejected() {
        Integer invalidStatus;
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            setRequest(TOKEN_IN_PROGRESS, ACTION_ID, 'A'.repeat(43));
            Test.startTest();
            DNAMSIDPCallbackAPI.receiveCallbackPost();
            invalidStatus = RestContext.response.statusCode;
            setRequest(TOKEN_IN_PROGRESS, ACTION_ID, '');
            DNAMSIDPCallbackAPI.receiveCallbackPost();
            Test.stopTest();
            Assert.areEqual(401, invalidStatus, 'Invalid signature is 401');
            Assert.areEqual(401, RestContext.response.statusCode, 'Missing signature is 401');
            Assert.isNull(getRow(TOKEN_IN_PROGRESS).CallbackReceivedAt__c, 'Row untouched');
        }
    }

    /**
     * @description Signed but unknown token, blank token, or action mismatch: 400.
     **/
    @IsTest
    static void testUnknownTokenOrMismatchRejected() {
        List<Integer> statuses = new List<Integer>();
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            setRequest('00000000000000000000000000000000', ACTION_ID, null);
            DNAMSIDPCallbackAPI.receiveCallbackPost();
            statuses.add(RestContext.response.statusCode);
            setRequest('', ACTION_ID, null);
            DNAMSIDPCallbackAPI.receiveCallbackPost();
            statuses.add(RestContext.response.statusCode);
            setRequest(TOKEN_IN_PROGRESS, 'other-action', null);
            DNAMSIDPCallbackAPI.receiveCallbackPost();
            statuses.add(RestContext.response.statusCode);
            Test.stopTest();
            Assert.areEqual(new List<Integer>{ 400, 400, 400 }, statuses, 'Unknown, blank and mismatched are 400');
            Assert.areEqual('rejected', getResponseStatus(), 'Status rejected');
            Assert.isNull(getRow(TOKEN_IN_PROGRESS).CallbackReceivedAt__c, 'Row untouched');
        }
    }

    /**
     * @description Sets RestContext with the path-form callback URI built by DNAMSCallbackSignatureUtil (no query string).
     * @param token     Callback token
     * @param tamper    True replaces the signature segment with a wrong one
     **/
    private static void setPathRequest(String token, Boolean tamper) {
        Map<String, String> params = new Map<String, String>{
            DNAMSPipelineConstants.PARAM_TOKEN => token,
            DNAMSPipelineConstants.PARAM_ACTION_ID => ACTION_ID,
            DNAMSPipelineConstants.PARAM_ACTION_VERSION => ACTION_VERSION
        };
        String url = DNAMSCallbackSignatureUtil.buildCallbackUrl('https://example.my.salesforce-sites.com/idpcallback', params);
        String uri = url.substringAfter('/services/apexrest');
        RestRequest request = new RestRequest();
        request.httpMethod = 'POST';
        request.requestURI = tamper ? uri.substringBeforeLast('/') + '/' + 'B'.repeat(43) : uri;
        request.requestBody = Blob.valueOf('{"id":"exec-1","status":"SUCCEEDED"}');
        request.addHeader('Content-Type', 'application/json');
        RestContext.request = request;
        RestContext.response = new RestResponse();
    }

    /**
     * @description Path-form callback (no query string) is accepted and what IDP sent is stored on the row.
     **/
    @IsTest
    static void testPathCallbackAcceptedAndRecorded() {
        DNAMSIDPActionUtil.clientOverride = new DNAMSIDPStubCallout();
        DNAMSIDPStubCallout.stubBodyOverride = '{"TradeName":"Acme"}';
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            setPathRequest(TOKEN_IN_PROGRESS, false);
            Test.startTest();
            DNAMSIDPCallbackAPI.receiveCallbackPost();
            Test.stopTest();
            Assert.areEqual(200, RestContext.response.statusCode, 'Path callback accepted');
            AIReviewStageResult__c row = [
                SELECT CallbackReceivedAt__c, CallbackPayload__c FROM AIReviewStageResult__c
                WHERE CallbackToken__c = :TOKEN_IN_PROGRESS WITH SYSTEM_MODE LIMIT 1
            ];
            Assert.isNotNull(row.CallbackReceivedAt__c, 'Callback time stamped');
            Assert.isTrue(row.CallbackPayload__c.contains('"status":"SUCCEEDED"'), 'Body recorded: ' + row.CallbackPayload__c);
            Assert.isTrue(row.CallbackPayload__c.startsWith('POST ') && row.CallbackPayload__c.contains('/***'), 'Signature masked');
        }
    }

    /**
     * @description A refused callback is no longer silent: 401 plus a Callback Rejected log with what was sent.
     **/
    @IsTest
    static void testRejectedCallbackIsLogged() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            setPathRequest(TOKEN_IN_PROGRESS, true);
            Test.startTest();
            DNAMSIDPCallbackAPI.receiveCallbackPost();
            Test.stopTest();
            Assert.areEqual(401, RestContext.response.statusCode, 'Tampered signature refused');
            List<AIReviewErrorLog__c> logs = [
                SELECT ErrorType__c, Severity__c, Message__c, RawPayload__c FROM AIReviewErrorLog__c
                WHERE ErrorType__c = :DNAMSPipelineConstants.ERROR_CALLBACK_REJECTED WITH SYSTEM_MODE
            ];
            Assert.areEqual(1, logs.size(), 'One rejection log');
            Assert.areEqual(DNAMSPipelineConstants.SEVERITY_WARNING, logs[0].Severity__c, 'Logged as a warning');
            Assert.isTrue(logs[0].Message__c.contains('401'), 'Reason states 401: ' + logs[0].Message__c);
            Assert.isFalse(logs[0].RawPayload__c.contains('B'.repeat(43)), 'Signature never stored');
        }
    }

    /**
     * @description IDP calls back with PATCH: the PATCH (and PUT) entry points run the same handler and accept it.
     **/
    @IsTest
    static void testPatchAndPutCallbacksReachHandler() {
        DNAMSIDPActionUtil.clientOverride = new DNAMSIDPStubCallout();
        DNAMSIDPStubCallout.stubBodyOverride = '{"TradeName":"Acme"}';
        Integer putStatus;
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            setPathRequest(TOKEN_IN_PROGRESS, false);
            RestContext.request.httpMethod = 'PATCH';
            Test.startTest();
            DNAMSIDPCallbackAPI.receiveCallbackPatch();
            Integer patchStatus = RestContext.response.statusCode;
            setPathRequest(TOKEN_COMPLETED, false);
            DNAMSIDPCallbackAPI.receiveCallbackPut();
            putStatus = RestContext.response.statusCode;
            Test.stopTest();
            Assert.areEqual(200, patchStatus, 'PATCH callback accepted');
            Assert.areEqual(200, putStatus, 'PUT reaches the handler (row already done, so ignored)');
            AIReviewStageResult__c row = [
                SELECT CallbackPayload__c FROM AIReviewStageResult__c WHERE CallbackToken__c = :TOKEN_IN_PROGRESS WITH SYSTEM_MODE LIMIT 1
            ];
            Assert.isTrue(row.CallbackPayload__c.startsWith('PATCH '), 'Method recorded: ' + row.CallbackPayload__c.left(40));
        }
    }
}
