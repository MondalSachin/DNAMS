/**
 * @description     Unit tests for DNAMSElementDocumentTypeUtil. Rows are injected in memory through rowsOverride, so
 *                  the tests never depend on the deployed DNAMSElementDocumentType__mdt records.
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
private class DNAMSElementDocumentTypeUtilTest {
    private static final String ADDRESS_VERIFICATION = 'Address Verification';

    /**
     * @description Builds one in-memory mapping row.
     * @param elementType  ElementType__c value
     * @param documentType DocumentType__c value
     * @param isActive     IsActive__c value
     * @return             The unsaved CMDT row
     **/
    private static DNAMSElementDocumentType__mdt row(String elementType, String documentType, Boolean isActive) {
        return new DNAMSElementDocumentType__mdt(
            ElementType__c = elementType,
            DocumentType__c = documentType,
            IdentifyingInstructions__c = 'Recognise the  ' + documentType + '\nby its title.',
            SortOrder__c = 1,
            IsActive__c = isActive
        );
    }

    /**
     * @description Active rows are grouped by lower-case element type in the given order; inactive and blank rows are skipped.
     **/
    @IsTest
    static void testGetByElementTypeGroupsActiveRows() {
        DNAMSElementDocumentTypeUtil.rowsOverride = new List<DNAMSElementDocumentType__mdt>{
            row(ADDRESS_VERIFICATION, 'Address Verification Form', true),
            row(ADDRESS_VERIFICATION, 'Utility Bill', true),
            row(ADDRESS_VERIFICATION, 'Retired Form', false),
            row('Org Chart', 'Org Chart', true),
            row(' ', 'Orphan', true)
        };
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            Map<String, List<DNAMSElementDocumentType__mdt>> rowsByType = DNAMSElementDocumentTypeUtil.getByElementType();
            Test.stopTest();

            Assert.areEqual(2, rowsByType.size(), 'Only the two element types with active, complete rows are returned');
            List<DNAMSElementDocumentType__mdt> address = rowsByType.get('address verification');
            Assert.areEqual(2, address.size(), 'The inactive Address Verification row is skipped');
            Assert.areEqual('Address Verification Form', address[0].DocumentType__c, 'Sort order is kept');
            Assert.areEqual('Utility Bill', address[1].DocumentType__c, 'Sort order is kept');
            Assert.areEqual(1, rowsByType.get('org chart').size(), 'Org Chart has its single row');
        }
    }

    /**
     * @description Prompt text has one "- <type>: <instructions>" line per row with whitespace collapsed; no rows -> null.
     **/
    @IsTest
    static void testBuildPromptTextFormatsLines() {
        DNAMSElementDocumentType__mdt noInstructions = row(ADDRESS_VERIFICATION, 'Utility Bill', true);
        noInstructions.IdentifyingInstructions__c = null;
        List<DNAMSElementDocumentType__mdt> rows = new List<DNAMSElementDocumentType__mdt>{
            row(ADDRESS_VERIFICATION, 'Address Verification Form', true),
            noInstructions
        };
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            String text = DNAMSElementDocumentTypeUtil.buildPromptText(rows);
            String empty = DNAMSElementDocumentTypeUtil.buildPromptText(new List<DNAMSElementDocumentType__mdt>());
            Test.stopTest();

            Assert.areEqual(
                '- Address Verification Form: Recognise the Address Verification Form by its title.\n- Utility Bill',
                text,
                'One normalised line per accepted document type'
            );
            Assert.isNull(empty, 'No rows gives no prompt text, so the caller can fall back');
        }
    }

    /**
     * @description Accepted names are the lower-case document types; null rows give an empty set.
     **/
    @IsTest
    static void testGetAcceptedNamesLowerCases() {
        List<DNAMSElementDocumentType__mdt> rows = new List<DNAMSElementDocumentType__mdt>{
            row(ADDRESS_VERIFICATION, 'Address Verification Form', true),
            row(ADDRESS_VERIFICATION, 'Utility Bill ', true)
        };
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            Set<String> names = DNAMSElementDocumentTypeUtil.getAcceptedNames(rows);
            Set<String> none = DNAMSElementDocumentTypeUtil.getAcceptedNames(null);
            Test.stopTest();

            Assert.areEqual(new Set<String>{ 'address verification form', 'utility bill' }, names, 'Trimmed, lower-case names');
            Assert.isTrue(none.isEmpty(), 'Null rows give an empty set');
        }
    }

    /**
     * @description Without an override the deployed records are read; whatever is deployed, keys are lower case and rows active.
     **/
    @IsTest
    static void testGetByElementTypeReadsDeployedRecords() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            Map<String, List<DNAMSElementDocumentType__mdt>> rowsByType = DNAMSElementDocumentTypeUtil.getByElementType();
            Test.stopTest();

            for (String key : rowsByType.keySet()) {
                Assert.areEqual(key.toLowerCase(), key, 'Keys are lower case');
                for (DNAMSElementDocumentType__mdt mapping : rowsByType.get(key)) {
                    Assert.isTrue(mapping.IsActive__c, 'Only active rows are returned');
                }
            }
        }
    }
}
