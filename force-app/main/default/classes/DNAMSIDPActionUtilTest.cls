/**
 * @description     Unit tests for DNAMSIDPActionUtil.
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
private class DNAMSIDPActionUtilTest {
    /**
     * @description Active actions are keyed by lower-case document type and resolve again by DeveloperName.
     **/
    @IsTest
    static void testActionLookups() {
        Map<String, DNAMSIDPWrapper.ActionConfig> actionByType;
        DNAMSIDPWrapper.ActionConfig byName;
        DNAMSIDPWrapper.ActionConfig unknown;
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            actionByType = DNAMSIDPActionUtil.getActionsByDocumentType();
            DNAMSIDPWrapper.ActionConfig first = actionByType.values().isEmpty() ? null : actionByType.values()[0];
            byName = DNAMSIDPActionUtil.getActionByName(first?.developerName);
            unknown = DNAMSIDPActionUtil.getActionByName('DoesNotExistAction');
            Test.stopTest();
        }
        Assert.isFalse(actionByType.isEmpty(), 'DNAMSIDPAction__mdt records are deployed');
        for (String documentType : actionByType.keySet()) {
            Assert.areEqual(actionByType.get(documentType).documentType.toLowerCase(), documentType, 'Key is the lower-case document type');
        }
        DNAMSIDPWrapper.ActionConfig expected = actionByType.values()[0];
        Assert.areEqual(expected.actionId, byName.actionId, 'Lookup by name returns the same action');
        Assert.isTrue(String.isNotBlank(byName.expectedStructure) && byName.getPath.contains('{executionId}'), 'Full config is read');
        Assert.isNull(unknown, 'Unknown name returns null');
    }

    /**
     * @description Mode selects the client; the override wins.
     **/
    @IsTest
    static void testGetClientByMode() {
        IDocumentExtractionClient liveClient;
        IDocumentExtractionClient stubClient;
        IDocumentExtractionClient overrideClient;
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            DNAMS_PackageReviewPipelineService.settingsOverride = new DNAMS_Pipeline_Setting__mdt(IDPMode__c = DNAMSPipelineConstants.IDP_MODE_LIVE);
            liveClient = DNAMSIDPActionUtil.getClient();
            DNAMS_PackageReviewPipelineService.settingsOverride = new DNAMS_Pipeline_Setting__mdt(IDPMode__c = DNAMSPipelineConstants.IDP_MODE_STUB);
            stubClient = DNAMSIDPActionUtil.getClient();
            DNAMSIDPActionUtil.clientOverride = new DNAMSIDPStubCallout();
            DNAMS_PackageReviewPipelineService.settingsOverride = new DNAMS_Pipeline_Setting__mdt(IDPMode__c = DNAMSPipelineConstants.IDP_MODE_LIVE);
            overrideClient = DNAMSIDPActionUtil.getClient();
            Test.stopTest();
        }
        Assert.isTrue(liveClient instanceof DNAMSIDPCallout, 'Live mode uses the HTTP client');
        Assert.isTrue(stubClient instanceof DNAMSIDPStubCallout, 'Stub mode uses the stub client');
        Assert.isTrue(overrideClient instanceof DNAMSIDPStubCallout, 'clientOverride wins');
    }
}
