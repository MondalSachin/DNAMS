/**
 * @description     Unit tests for DNAMSCallbackSignatureUtil.
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
private class DNAMSCallbackSignatureUtilTest {
    /**
     * @description Signing key for every test.
     **/
    @TestSetup
    static void setupData() {
        insert new DNAMSIDPSecret__c(SetupOwnerId = UserInfo.getOrganizationId(), SigningKey__c = 'test-key');
    }

    /**
     * @description Callback parameters used by the tests.
     * @return      t, a, av
     **/
    private static Map<String, String> getParams() {
        return new Map<String, String>{
            DNAMSPipelineConstants.PARAM_TOKEN => 'abc123',
            DNAMSPipelineConstants.PARAM_ACTION_ID => 'action-1',
            DNAMSPipelineConstants.PARAM_ACTION_VERSION => '1.0.0'
        };
    }

    /**
     * @description Token is 32 hex characters and random.
     **/
    @IsTest
    static void testGenerateTokenIsRandomHex() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            String first = DNAMSCallbackSignatureUtil.generateToken();
            String second = DNAMSCallbackSignatureUtil.generateToken();
            Test.stopTest();
            Assert.isTrue(Pattern.matches('[0-9a-f]{32}', first), 'Token is 32 lower-case hex characters');
            Assert.areNotEqual(first, second, 'Tokens are random');
        }
    }

    /**
     * @description Signature round trip, independent of map order; tampering and junk are rejected.
     **/
    @IsTest
    static void testSignAndVerify() {
        Map<String, String> params = getParams();
        Map<String, String> tampered = getParams();
        tampered.put(DNAMSPipelineConstants.PARAM_TOKEN, 'abc124');
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            String signature = DNAMSCallbackSignatureUtil.sign(params);
            Boolean isValid = DNAMSCallbackSignatureUtil.isValidSignature(params, signature);
            Boolean isTamperedValid = DNAMSCallbackSignatureUtil.isValidSignature(tampered, signature);
            Boolean isJunkValid = DNAMSCallbackSignatureUtil.isValidSignature(params, 'not-a-signature');
            Boolean isMissingValid = DNAMSCallbackSignatureUtil.isValidSignature(params, null);
            Test.stopTest();
            Assert.areEqual(43, signature.length(), 'Base64-URL HMAC-SHA256 without padding');
            Assert.isFalse(signature.contains('=') || signature.contains('+') || signature.contains('/'), 'URL-safe alphabet');
            Assert.isTrue(isValid, 'Own signature verifies');
            Assert.isFalse(isTamperedValid, 'Changed parameter fails');
            Assert.isFalse(isJunkValid, 'Malformed signature fails');
            Assert.isFalse(isMissingValid, 'Missing signature fails');
        }
    }

    /**
     * @description Callback URL has the path, sorted encoded params and a verifiable sig.
     **/
    @IsTest
    static void testBuildCallbackUrl() {
        Map<String, String> params = getParams();
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            String url = DNAMSCallbackSignatureUtil.buildCallbackUrl('https://example.my.salesforce-sites.com/idpcallback/', params);
            Test.stopTest();
            String expectedStart = 'https://example.my.salesforce-sites.com/idpcallback' + DNAMSPipelineConstants.CALLBACK_PATH
                + '/abc123/action-1/1.0.0/';
            Assert.isTrue(url.startsWith(expectedStart), 'Base, path and token/action/version segments: ' + url);
            Assert.isFalse(url.contains('?'), 'No query string to lose');
            Assert.isTrue(DNAMSCallbackSignatureUtil.isValidSignature(params, url.substringAfterLast('/')), 'Last segment is the signature');
        }
    }

    /**
     * @description Blank key: sign throws, verify returns false.
     **/
    @IsTest
    static void testBlankKey() {
        String message;
        Boolean isValid;
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSIDPSecret__c secret = DNAMSIDPSecret__c.getOrgDefaults();
            secret.SigningKey__c = null;
            update as system secret;
            Test.startTest();
            isValid = DNAMSCallbackSignatureUtil.isValidSignature(getParams(), 'a'.repeat(43));
            try {
                DNAMSCallbackSignatureUtil.sign(getParams());
            } catch (DNAMSPipelineException e) {
                message = e.getMessage();
            }
            Test.stopTest();
        }
        Assert.isFalse(isValid, 'No key means no valid signature');
        Assert.isTrue(message.contains('SigningKey__c'), 'Missing key is reported');
    }
}
