/**
 * @description     Handler for DNAMSPackageTypeElementMapTrigger. Stamps Unique_Key__c = Package Type + ':' +
 *                  Element Type Id (18 characters) before every insert and update. The field is unique and
 *                  case-sensitive, so a duplicate Package Type and Element Type pair fails the save, and a manual
 *                  edit of the key is always overwritten.
 * @author          Abhishek Dutta
 * @group           DNAMS Package
 * @last modified on 2026-11-09
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-09   Abhishek Dutta  Initial version
 **/
public with sharing class DNAMSPackageTypeElementMapTriggerHandler {
    public static final String KEY_SEPARATOR = ':';

    /**
     * @description Sets the unique key on each row from its Package Type and Element Type.
     * @param mappings Trigger.new of DNAMS_Package_Type_Element_Map__c (before insert / before update)
     **/
    public static void setUniqueKeys(List<DNAMS_Package_Type_Element_Map__c> mappings) {
        for (DNAMS_Package_Type_Element_Map__c mapping : mappings) {
            mapping.Unique_Key__c = uniqueKey(mapping.Package_Type__c, mapping.Element_Type__c);
        }
    }

    /**
     * @description Builds the unique key for a Package Type and Element Type pair (also used by the seed script
     *              and upserts that match on Unique_Key__c).
     * @param packageType   Package Type picklist value
     * @param elementTypeId Element Type record Id
     * @return              Package Type + ':' + 18-character Element Type Id, or null when either part is blank
     **/
    public static String uniqueKey(String packageType, Id elementTypeId) {
        if (String.isBlank(packageType) || elementTypeId == null) {
            return null;
        }
        return packageType + KEY_SEPARATOR + String.valueOf(elementTypeId);
    }
}
