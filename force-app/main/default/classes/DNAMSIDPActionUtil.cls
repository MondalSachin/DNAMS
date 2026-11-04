/**
 * @description     Reads the DNAMSIDPAction__mdt mapping (document type to MuleSoft IDP action) and resolves the IDP
 *                  client for the configured mode (DNAMS_Pipeline_Setting__mdt.IDPMode__c).
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
public inherited sharing class DNAMSIDPActionUtil {
    @TestVisible
    private static IDocumentExtractionClient clientOverride;
    @TestVisible
    private static Map<String, DNAMSIDPWrapper.ActionConfig> actionsOverride;

    /**
     * @description Active IDP actions keyed by DocumentType__c in lower case.
     * @return      Map of lower-case document type to action (actionsOverride when set by a test)
     **/
    public static Map<String, DNAMSIDPWrapper.ActionConfig> getActionsByDocumentType() {
        if (actionsOverride != null) {
            return actionsOverride;
        }
        Map<String, DNAMSIDPWrapper.ActionConfig> actionByType = new Map<String, DNAMSIDPWrapper.ActionConfig>();
        // SOQL, not getAll(): getAll() truncates the ExpectedStructure__c long text area to 255 characters
        for (DNAMSIDPAction__mdt record : [
            SELECT DeveloperName, DocumentType__c, ActionId__c, ActionVersion__c, PostPath__c, GetPath__c,
                ExpectedStructure__c, StubResource__c
            FROM DNAMSIDPAction__mdt
            WHERE IsActive__c = TRUE
            WITH SYSTEM_MODE
        ]) {
            if (String.isNotBlank(record.DocumentType__c)) {
                actionByType.put(record.DocumentType__c.toLowerCase(), toConfig(record));
            }
        }
        return actionByType;
    }

    /**
     * @description One IDP action by DeveloperName, active or not (rows created earlier keep resolving).
     * @param developerName DNAMSIDPAction__mdt DeveloperName (AIReviewStageResult__c.IDPActionName__c)
     * @return              The action, or null when no record has that name
     **/
    public static DNAMSIDPWrapper.ActionConfig getActionByName(String developerName) {
        List<DNAMSIDPAction__mdt> records = [
            SELECT DeveloperName, DocumentType__c, ActionId__c, ActionVersion__c, PostPath__c, GetPath__c,
                ExpectedStructure__c, StubResource__c
            FROM DNAMSIDPAction__mdt
            WHERE DeveloperName = :developerName
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return records.isEmpty() ? null : toConfig(records[0]);
    }

    /**
     * @description IDP client for the configured mode: DNAMSIDPCallout when IDPMode__c is Live, otherwise the stub.
     * @return      Client implementation (clientOverride when set by a test)
     **/
    public static IDocumentExtractionClient getClient() {
        if (clientOverride != null) {
            return clientOverride;
        }
        Boolean isLive = DNAMS_PackageReviewPipelineService.settings().IDPMode__c == DNAMSPipelineConstants.IDP_MODE_LIVE;
        return isLive ? (IDocumentExtractionClient) new DNAMSIDPCallout() : new DNAMSIDPStubCallout();
    }

    /**
     * @description Copies a CMDT record into the wrapper.
     * @param record DNAMSIDPAction__mdt record
     * @return       Action wrapper
     **/
    private static DNAMSIDPWrapper.ActionConfig toConfig(DNAMSIDPAction__mdt record) {
        DNAMSIDPWrapper.ActionConfig config = new DNAMSIDPWrapper.ActionConfig();
        config.developerName = record.DeveloperName;
        config.documentType = record.DocumentType__c;
        config.actionId = record.ActionId__c;
        config.actionVersion = record.ActionVersion__c;
        config.postPath = record.PostPath__c;
        config.getPath = record.GetPath__c;
        config.expectedStructure = record.ExpectedStructure__c;
        config.stubResource = record.StubResource__c;
        return config;
    }
}
