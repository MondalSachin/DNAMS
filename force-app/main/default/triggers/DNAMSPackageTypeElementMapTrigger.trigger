/**
 * @description     Sets DNAMS_Package_Type_Element_Map__c.Unique_Key__c on every save, so a second row for the same
 *                  Package Type and Element Type is rejected by the unique field.
 * @author          Abhishek Dutta
 * @group           DNAMS Package
 * @last modified on 2026-11-09
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-09   Abhishek Dutta  Initial version
 **/
trigger DNAMSPackageTypeElementMapTrigger on DNAMS_Package_Type_Element_Map__c(before insert, before update) {
    DNAMSPackageTypeElementMapTriggerHandler.setUniqueKeys(Trigger.new);
}
