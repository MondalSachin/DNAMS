/**
 * @description     Shared test data for the DNAMS AI review extraction tests: an admin user, a Term Renewal package
 *                  ready for extraction (classified files on four elements and a Running run), in-memory pipeline
 *                  settings and stage result builders. Insert the user first, then build data inside System.runAs.
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
public inherited sharing class DNAMSPipelineTestHelper {
    public static final String ADMIN_PROFILE = 'System Administrator';
    public static final Set<String> ADMIN_PERMISSION_SETS = new Set<String>{ 'DNAMS_Package_Access', 'DNAMSIDPIntegration' };
    public static final String SIGNING_KEY = 'test-signing-key';

    /** Document type (as stamped on ContentVersion.DocumentClassifiedAs__c) to the element type that holds it. */
    public static final Map<String, String> ELEMENT_TYPE_BY_DOCUMENT_TYPE = new Map<String, String>{
        'Dealer Application' => 'Dealer Application',
        'Address Verification Form' => 'Address Verification',
        'Utility Bill' => 'Address Verification',
        'Org Chart' => 'Org Chart',
        'Photographs of Facility' => 'Photographs of Facility'
    };

    /** Document type to its DNAMSIDPAction__mdt DeveloperName. */
    public static final Map<String, String> ACTION_NAME_BY_DOCUMENT_TYPE = new Map<String, String>{
        'Dealer Application' => 'DealerApplication',
        'Address Verification Form' => 'AddressVerificationForm',
        'Utility Bill' => 'UtilityBill',
        'Org Chart' => 'OrgChart',
        'Photographs of Facility' => 'PhotographsOfFacility'
    };

    /** A small IDP GET envelope with one field, set on Completed rows built by createStageResult. */
    public static final String TEST_RESPONSE_JSON =
        '{"id":"stub-test","status":"SUCCEEDED","pages":[{"page":1,"fields":{"DealerCode":{"value":"TCE00087"}},"tables":{}}]}';

    /** Expected structure that TEST_RESPONSE_JSON matches exactly. */
    public static final String TEST_EXPECTED_STRUCTURE =
        '{"configuration":{"content":{"output":{"fields":{"DealerCode":{"required":false}},"tables":{}}}}}';

    /**
     * @description Ids of the records created by createExtractionFixture.
     **/
    public class PipelineFixture {
        public Id packageId;
        public Id runId;
        public Map<String, Id> elementIdByType = new Map<String, Id>();
        public Map<String, Id> versionIdByDocumentType = new Map<String, Id>();
    }

    /**
     * @description Inserts an active System Administrator with the DNAMS permission sets that exist in the org.
     * @return The inserted user
     * @example
     *   User admin = DNAMSPipelineTestHelper.getAdminUser();
     *   System.runAs(admin) { ... }
     **/
    public static User getAdminUser() {
        List<Profile> adminProfiles = [SELECT Id FROM Profile WHERE Name = :ADMIN_PROFILE WITH SYSTEM_MODE LIMIT 1];
        String uniqueKey = EncodingUtil.convertToHex(Crypto.generateAesKey(128)).left(12);
        User adminUser = new User(
            Alias = 'dnamsadm',
            Email = 'dnams.admin.' + uniqueKey + '@example.com',
            EmailEncodingKey = 'UTF-8',
            FirstName = 'DNAMS',
            LastName = 'Test Admin',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = adminProfiles[0].Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'dnams.admin.' + uniqueKey + '@example.com.test'
        );
        Database.insert(adminUser, AccessLevel.SYSTEM_MODE);
        List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
        for (PermissionSet permissionSetObj : [
            SELECT Id
            FROM PermissionSet
            WHERE Name IN :ADMIN_PERMISSION_SETS
            WITH SYSTEM_MODE
        ]) {
            assignments.add(new PermissionSetAssignment(AssigneeId = adminUser.Id, PermissionSetId = permissionSetObj.Id));
        }
        // Partial success: a permission set restricted to another license must not break the tests.
        Database.insert(assignments, false, AccessLevel.SYSTEM_MODE);
        return adminUser;
    }

    /**
     * @description Inserts a Term Renewal package ready for extraction: four element types, one classified file per
     *              document type (two on Address Verification), Passed classification, a Running run with
     *              Extraction Pending, and the callback signing key. Call inside System.runAs.
     * @return The fixture Ids
     **/
    public static PipelineFixture createExtractionFixture() {
        PipelineFixture fixture = new PipelineFixture();
        Database.insert(elementTypes(), AccessLevel.SYSTEM_MODE);
        Account dealer = new Account(Name = 'DNAMS Test Dealer', AccountNumber = 'TCE00087');
        Database.insert(dealer, AccessLevel.SYSTEM_MODE);
        DNAMS_Package__c packageObj = new DNAMS_Package__c(Type__c = 'Term Renewal', Status__c = 'Initiated', Buying_Dealer__c = dealer.Id);
        Database.insert(packageObj, AccessLevel.SYSTEM_MODE);
        fixture.packageId = packageObj.Id;

        List<DNAMS_Package_Element__c> elements = [
            SELECT Id, Name
            FROM DNAMS_Package_Element__c
            WHERE Package__c = :packageObj.Id
            WITH SYSTEM_MODE
        ];
        for (DNAMS_Package_Element__c element : elements) {
            fixture.elementIdByType.put(element.Name, element.Id);
            element.Classification_Status__c = DNAMS_PackageReviewPipelineService.STAGE_PASSED;
        }
        Database.update(elements, AccessLevel.SYSTEM_MODE);

        List<ContentVersion> versions = classifiedVersions(fixture.elementIdByType);
        Database.insert(versions, AccessLevel.SYSTEM_MODE);
        for (ContentVersion version : versions) {
            fixture.versionIdByDocumentType.put(version.DocumentClassifiedAs__c, version.Id);
        }

        AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(
            Package__c = packageObj.Id,
            Status__c = DNAMS_PackageReviewPipelineService.RUN_RUNNING,
            Trigger_Source__c = DNAMS_PackageReviewPipelineService.SOURCE_DEALER_SUBMIT,
            Classification_Processing_Status__c = 'Completed',
            ExtractionProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_PENDING,
            Started_At__c = System.now()
        );
        Database.insert(run, AccessLevel.SYSTEM_MODE);
        fixture.runId = run.Id;

        Database.insert(new DNAMSIDPSecret__c(SetupOwnerId = UserInfo.getOrganizationId(), SigningKey__c = SIGNING_KEY), AccessLevel.SYSTEM_MODE);
        return fixture;
    }

    /**
     * @description In-memory pipeline settings for tests; assign to DNAMS_PackageReviewPipelineService.settingsOverride.
     * @return The settings record (not saved)
     **/
    public static DNAMS_Pipeline_Setting__mdt getPipelineSettings() {
        return new DNAMS_Pipeline_Setting__mdt(
            IDPMode__c = DNAMSPipelineConstants.IDP_MODE_LIVE,
            ExtractionBatchSize__c = 10,
            IDPTimeoutMinutes__c = 10,
            MaxFileSizeMB__c = 3,
            AllowedFileExtensions__c = 'pdf',
            IDPCallbackSiteURL__c = 'https://example.my.salesforce-sites.com/idpcallback',
            IDPNamedCredential__c = 'DNAMSMuleSoftIDP',
            AdminQueue__c = 'DNAMSAdminTeam',
            Batch_Size__c = 1,
            Max_Attempts__c = 1,
            Min_Accepted_Confidence__c = 'MODERATE',
            Min_Auto_Accept_Confidence__c = 'FULLY',
            Prompt_Template__c = 'DNAMS_DocumentClassifier_Prompt',
            Narrative_Prompt_Template__c = 'DNAMS_PackageIssueNarrator_Prompt'
        );
    }

    /**
     * @description Builds an extraction stage row (no DML) for a fixture document type, linked to the fixture run,
     *              element and content version. Completed rows get TEST_RESPONSE_JSON; every row gets a unique
     *              callback token and the title "<documentType> test".
     * @param fixture          The extraction fixture
     * @param documentType     A key of ELEMENT_TYPE_BY_DOCUMENT_TYPE, e.g. 'Utility Bill'
     * @param processingStatus ProcessingStatus__c value, e.g. DNAMSPipelineConstants.ROW_COMPLETED
     * @return The unsaved stage row
     **/
    public static AIReviewStageResult__c createStageResult(PipelineFixture fixture, String documentType, String processingStatus) {
        String elementType = ELEMENT_TYPE_BY_DOCUMENT_TYPE.get(documentType);
        return new AIReviewStageResult__c(
            ReviewRun__c = fixture.runId,
            PackageElement__c = fixture.elementIdByType.get(elementType),
            Stage__c = DNAMSPipelineConstants.STAGE_EXTRACTION,
            ElementType__c = elementType,
            DocumentType__c = documentType,
            DocumentTitle__c = documentType + ' test',
            ContentVersionId__c = fixture.versionIdByDocumentType.get(documentType),
            IDPActionName__c = ACTION_NAME_BY_DOCUMENT_TYPE.get(documentType),
            IDPActionVersion__c = '1.0.0',
            CallbackToken__c = EncodingUtil.convertToHex(Crypto.generateAesKey(128)),
            ProcessingStatus__c = processingStatus,
            RawStageResponseJSON__c = processingStatus == DNAMSPipelineConstants.ROW_COMPLETED ? TEST_RESPONSE_JSON : null
        );
    }

    /**
     * @description Builds one stage row per fixture document type, all with the same status (no DML).
     * @param fixture          The extraction fixture
     * @param processingStatus ProcessingStatus__c value for every row
     * @return Rows keyed by document type
     **/
    public static Map<String, AIReviewStageResult__c> createStageResults(PipelineFixture fixture, String processingStatus) {
        Map<String, AIReviewStageResult__c> rowByDocumentType = new Map<String, AIReviewStageResult__c>();
        for (String documentType : ELEMENT_TYPE_BY_DOCUMENT_TYPE.keySet()) {
            rowByDocumentType.put(documentType, createStageResult(fixture, documentType, processingStatus));
        }
        return rowByDocumentType;
    }

    /**
     * @description The four active element types used by the fixture, in sort order.
     * @return Unsaved element types
     **/
    private static List<DNAMS_Element_Type__c> elementTypes() {
        List<DNAMS_Element_Type__c> types = new List<DNAMS_Element_Type__c>();
        Integer sortOrder = 1;
        for (String elementType : new Set<String>(ELEMENT_TYPE_BY_DOCUMENT_TYPE.values())) {
            types.add(new DNAMS_Element_Type__c(Name = elementType, Is_Active__c = true, Is_Required__c = true, Sort_Order__c = sortOrder++));
        }
        return types;
    }

    /**
     * @description One small PDF per document type on its element, stamped with the classified document type.
     * @param elementIdByType Element Id keyed by element type name
     * @return Unsaved content versions
     **/
    private static List<ContentVersion> classifiedVersions(Map<String, Id> elementIdByType) {
        List<ContentVersion> versions = new List<ContentVersion>();
        for (String documentType : ELEMENT_TYPE_BY_DOCUMENT_TYPE.keySet()) {
            String title = documentType + ' test';
            versions.add(
                new ContentVersion(
                    Title = title,
                    PathOnClient = title + '.pdf',
                    VersionData = Blob.valueOf('%PDF-1.4 ' + title),
                    FirstPublishLocationId = elementIdByType.get(ELEMENT_TYPE_BY_DOCUMENT_TYPE.get(documentType)),
                    DocumentClassifiedAs__c = documentType
                )
            );
        }
        return versions;
    }
}
