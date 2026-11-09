/**
 * @description     Tests DNAMSPackageTypeElementMapTrigger and DNAMSPackageTypeElementMapTriggerHandler: the unique key
 *                  is stamped on insert and update, a duplicate Package Type and Element Type pair is rejected, and a
 *                  manual key edit is overwritten.
 * @author          Abhishek Dutta
 * @group           DNAMS Package
 * @last modified on 2026-11-09
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-09   Abhishek Dutta  Initial version
 **/
@IsTest
private class DNAMSPackageTypeElementMapTest {
    private static final String TERM_RENEWAL = 'Term Renewal';
    private static final String BUY_SELL = 'Buy/Sell change of Ownership';

    /**
     * @description Two element types.
     **/
    @TestSetup
    static void setup() {
        insert new List<DNAMS_Element_Type__c>{
            new DNAMS_Element_Type__c(Name = 'Dealer Application', Sort_Order__c = 1),
            new DNAMS_Element_Type__c(Name = 'Org Chart', Sort_Order__c = 2)
        };
    }

    /**
     * @description Element type Id by name.
     * @param name Element type name
     * @return     Element type Id
     **/
    private static Id elementTypeId(String name) {
        return [SELECT Id FROM DNAMS_Element_Type__c WHERE Name = :name].Id;
    }

    /**
     * @description Reloads a mapping's unique key.
     * @param mappingId Mapping Id
     * @return          Unique key
     **/
    private static String keyOf(Id mappingId) {
        return [SELECT Unique_Key__c FROM DNAMS_Package_Type_Element_Map__c WHERE Id = :mappingId].Unique_Key__c;
    }

    @IsTest
    static void testInsertAndUpdateStampUniqueKey() {
        Id applicationId = elementTypeId('Dealer Application');
        Id orgChartId = elementTypeId('Org Chart');
        DNAMS_Package_Type_Element_Map__c mapping = new DNAMS_Package_Type_Element_Map__c(
            Package_Type__c = TERM_RENEWAL,
            Element_Type__c = applicationId,
            Is_Active__c = true
        );

        Test.startTest();
        insert mapping;
        String insertedKey = keyOf(mapping.Id);
        update new DNAMS_Package_Type_Element_Map__c(Id = mapping.Id, Element_Type__c = orgChartId, Unique_Key__c = 'manual');
        Test.stopTest();

        Assert.areEqual(TERM_RENEWAL + ':' + String.valueOf(applicationId), insertedKey, 'Key is Package Type:18-char Element Type Id');
        Assert.areEqual(18, insertedKey.substringAfter(':').length(), 'Element Type Id is 18 characters');
        Assert.areEqual(TERM_RENEWAL + ':' + String.valueOf(orgChartId), keyOf(mapping.Id), 'Update recomputes the key and ignores a manual value');
    }

    @IsTest
    static void testDuplicatePairIsRejected() {
        Id applicationId = elementTypeId('Dealer Application');
        insert new DNAMS_Package_Type_Element_Map__c(Package_Type__c = TERM_RENEWAL, Element_Type__c = applicationId);

        Test.startTest();
        Database.SaveResult duplicate = Database.insert(
            new DNAMS_Package_Type_Element_Map__c(Package_Type__c = TERM_RENEWAL, Element_Type__c = applicationId, Is_Active__c = true),
            false
        );
        Database.SaveResult otherType = Database.insert(
            new DNAMS_Package_Type_Element_Map__c(Package_Type__c = BUY_SELL, Element_Type__c = applicationId),
            false
        );
        Test.stopTest();

        Assert.isFalse(duplicate.isSuccess(), 'Same Package Type and Element Type twice is rejected');
        Assert.areEqual(StatusCode.DUPLICATE_VALUE, duplicate.getErrors()[0].getStatusCode(), duplicate.getErrors()[0].getMessage());
        Assert.isTrue(otherType.isSuccess(), 'The same Element Type on another Package Type is allowed');
    }

    @IsTest
    static void testUniqueKeyIsNullWhenAPartIsBlank() {
        Assert.isNull(DNAMSPackageTypeElementMapTriggerHandler.uniqueKey(null, elementTypeId('Org Chart')), 'No Package Type');
        Assert.isNull(DNAMSPackageTypeElementMapTriggerHandler.uniqueKey(TERM_RENEWAL, null), 'No Element Type');
    }
}
