/**
 * @description     Unit tests for DNAMSIDPStubCallout.
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
private class DNAMSIDPStubCalloutTest {
    /**
     * @description Submit returns a stub execution id without callouts.
     **/
    @IsTest
    static void testSubmitDocumentReturnsStubId() {
        DNAMSIDPWrapper.SubmitResult result;
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            result = new DNAMSIDPStubCallout().submitDocument(new DNAMSIDPWrapper.SubmitRequest());
            Test.stopTest();
        }
        Assert.isTrue(result.isSuccess, 'Stub submit succeeds');
        Assert.isTrue(Pattern.matches('stub-[0-9a-f]{16}', result.executionId), 'stub- + 16 hex: ' + result.executionId);
        Assert.areEqual(0, Limits.getCallouts(), 'No callout made');
    }

    /**
     * @description Fetch wraps the value-only stub in the flat IDP envelope, which normalizes back to the same values.
     **/
    @IsTest
    static void testFetchExecutionWrapsStubBody() {
        DNAMSIDPStubCallout.stubBodyOverride = '{"DealerCode":"40718","AddressTable":[{"Status":"Confirmed"}]}';
        DNAMSIDPWrapper.ExecutionResult result;
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            result = new DNAMSIDPStubCallout().fetchExecution(new DNAMSIDPWrapper.ActionConfig(), 'stub-1');
            Test.stopTest();
        }
        Map<String, Object> envelope = (Map<String, Object>) JSON.deserializeUntyped(result.responseBody);
        DNAMSIDPWrapper.NormalizedOutput output = DNAMSIDPWrapper.normalizeOutput(result.responseBody);
        Assert.isTrue(result.isSuccess, 'Stub fetch succeeds');
        Assert.areEqual(DNAMSPipelineConstants.IDP_SUCCEEDED, result.executionStatus, 'SUCCEEDED');
        Assert.areEqual('stub-1', envelope.get('id'), 'Execution id echoed');
        Assert.isTrue(envelope.containsKey('fields') && !envelope.containsKey('pages'), 'Flat envelope like the real IDP GET');
        Assert.areEqual('40718', output.fields.get('DealerCode'), 'Field round trip');
        Assert.areEqual('Confirmed', output.tables.get('AddressTable')[0].get('Status'), 'Table round trip');
    }

    /**
     * @description Missing static resource returns a 404 failure.
     **/
    @IsTest
    static void testFetchExecutionMissingResource() {
        DNAMSIDPWrapper.ActionConfig action = new DNAMSIDPWrapper.ActionConfig();
        action.stubResource = 'DNAMSIDPStubDoesNotExist';
        DNAMSIDPWrapper.ExecutionResult result;
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            result = new DNAMSIDPStubCallout().fetchExecution(action, 'stub-1');
            Test.stopTest();
        }
        Assert.isFalse(result.isSuccess, 'Missing resource fails');
        Assert.areEqual(404, result.statusCode, '404 reported');
    }
}
