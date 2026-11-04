/**
 * @description     Routes DNAMSIDPEvent__e (Start Extraction, Callback) to DNAMSIDPEventTriggerHandler.
 *                  Runs as the IDP integration user configured in PlatformEventSubscriberConfig DNAMSIDPEventSubscriberConfig.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
trigger DNAMSIDPEventTrigger on DNAMSIDPEvent__e(after insert) {
    DNAMSIDPEventTriggerHandler.handleEvents(Trigger.new);
}
