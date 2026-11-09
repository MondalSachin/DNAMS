/**
 * @description     Stub MuleSoft IDP client used when IDPMode__c is not Live. Makes no callouts: submit returns a
 *                  fake execution id, fetch returns the value-only JSON of the static resource named by
 *                  DNAMSIDPAction__mdt.StubResource__c wrapped in the real (flat) IDP GET envelope.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 * 1.1   2026-11-05   Sachin Mondal   Demo trigger: file names containing INCOMPLETE get the incomplete stub result
 **/
public inherited sharing class DNAMSIDPStubCallout implements IDocumentExtractionClient {
    private static final String STUB_PREFIX = 'stub-';
    // Demo trigger: a file whose name contains INCOMPLETE gets the action's "<StubResource>Incomplete" result (fields
    // missing), so extraction fails its structure check. The marker travels in the execution id.
    @TestVisible
    private static final String INCOMPLETE_MARKER = 'INCOMPLETE';
    private static final String INCOMPLETE_PREFIX = 'stub-incomplete-';
    private static final String INCOMPLETE_SUFFIX = 'Incomplete';
    private static final String STATUS_ACKNOWLEDGED = 'ACKNOWLEDGED';

    // Tests set this instead of depending on the DNAMSIDPStub* static resources being deployed
    @TestVisible
    private static String stubBodyOverride;

    /**
     * @description Returns a successful fake submission with execution id 'stub-' + 16 random hex characters.
     * @param request Submit request (not sent anywhere)
     * @return        Successful POST outcome
     **/
    public DNAMSIDPWrapper.SubmitResult submitDocument(DNAMSIDPWrapper.SubmitRequest request) {
        DNAMSIDPWrapper.SubmitResult result = new DNAMSIDPWrapper.SubmitResult();
        result.isSuccess = true;
        result.statusCode = 201;
        Boolean incomplete = (request?.fileName ?? '').toUpperCase().contains(INCOMPLETE_MARKER);
        result.executionId = (incomplete ? INCOMPLETE_PREFIX : STUB_PREFIX) + DNAMSCallbackSignatureUtil.generateToken().left(16);
        result.executionStatus = STATUS_ACKNOWLEDGED;
        result.responseBody = JSON.serialize(new Map<String, String>{ 'id' => result.executionId, 'status' => STATUS_ACKNOWLEDGED });
        return result;
    }

    /**
     * @description Returns SUCCEEDED with the stub resource body wrapped as the real IDP GET body {id, status, fields, tables}.
     * @param action      IDP action (stubResource names the static resource)
     * @param executionId Execution id echoed in the envelope
     * @return            GET outcome; isSuccess = false (404) when the static resource does not exist
     **/
    public DNAMSIDPWrapper.ExecutionResult fetchExecution(DNAMSIDPWrapper.ActionConfig action, String executionId) {
        DNAMSIDPWrapper.ExecutionResult result = new DNAMSIDPWrapper.ExecutionResult();
        Boolean incomplete = (executionId ?? '').startsWith(INCOMPLETE_PREFIX);
        String resourceName = incomplete && String.isNotBlank(action?.stubResource) ? action.stubResource + INCOMPLETE_SUFFIX : action?.stubResource;
        String stubBody = stubBodyOverride ?? loadStaticResource(resourceName);
        if (stubBody == null) {
            result.isSuccess = false;
            result.statusCode = 404;
            result.errorMessage = 'Stub static resource not found: ' + resourceName;
            return result;
        }
        DNAMSIDPWrapper.NormalizedOutput output = DNAMSIDPWrapper.normalizeOutput(stubBody);
        result.isSuccess = true;
        result.statusCode = 200;
        result.executionStatus = DNAMSPipelineConstants.IDP_SUCCEEDED;
        result.responseBody = JSON.serialize(new Map<String, Object>{
            'id' => executionId,
            'status' => DNAMSPipelineConstants.IDP_SUCCEEDED,
            'fields' => output.fields,
            'tables' => output.tables
        });
        return result;
    }

    /**
     * @description Reads a static resource body as text.
     * @param resourceName Static resource name
     * @return             Body text, or null when blank or not found
     **/
    private static String loadStaticResource(String resourceName) {
        if (String.isBlank(resourceName)) {
            return null;
        }
        List<StaticResource> resources = [SELECT Body FROM StaticResource WHERE Name = :resourceName WITH SYSTEM_MODE LIMIT 1];
        return resources.isEmpty() ? null : resources[0].Body.toString();
    }
}
