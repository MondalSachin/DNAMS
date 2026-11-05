import { LightningElement } from "lwc";
import { CloseActionScreenEvent } from "lightning/actions";

/**
 * Generate Transmittal quick action on DNAMS_Package__c. Placeholder until PDF generation exists: confirms the
 * request and closes.
 */
export default class DnamsGenerateTransmittal extends LightningElement {
  handleClose() {
    this.dispatchEvent(new CloseActionScreenEvent());
  }
}
