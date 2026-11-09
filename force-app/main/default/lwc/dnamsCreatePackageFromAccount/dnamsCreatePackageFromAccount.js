import { LightningElement, api, wire } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { CloseActionScreenEvent } from "lightning/actions";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { RefreshEvent } from "lightning/refresh";
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from "lightning/uiRecordApi";
import PACKAGE_OBJECT from "@salesforce/schema/DNAMS_Package__c";
import NAME_FIELD from "@salesforce/schema/DNAMS_Package__c.Name";
import PACKAGE_NAME_FIELD from "@salesforce/schema/DNAMS_Package__c.Package_Name__c";
import TYPE_FIELD from "@salesforce/schema/DNAMS_Package__c.Type__c";
import BUYING_DEALER_FIELD from "@salesforce/schema/DNAMS_Package__c.Buying_Dealer__c";
import PRIMARY_CONTACT_FIELD from "@salesforce/schema/DNAMS_Package__c.Primary_Contact__c";
import SELLING_DEALER_FIELD from "@salesforce/schema/DNAMS_Package__c.Selling_Dealer__c";

/**
 * Create Package quick action on Account. The account is the Dealer / Buying Dealer; the user picks the
 * Type, a Primary Contact of this account and an optional Selling Dealer. After saving it toasts
 * 'Package "<Package Name>" was created.' with the name linking to the new package (Package_Name__c is
 * computed by the before-insert trigger), refreshes the page and closes.
 */
export default class DnamsCreatePackageFromAccount extends NavigationMixin(LightningElement) {
  @api recordId;
  objectApiName = PACKAGE_OBJECT.objectApiName;
  typeField = TYPE_FIELD.fieldApiName;
  sellingDealerField = SELLING_DEALER_FIELD.fieldApiName;
  contactDisplayInfo = { additionalFields: ["Email"] };
  contactId;
  isSaving = false;
  createdRecordId;

  @wire(getRecord, {
    recordId: "$createdRecordId",
    optionalFields: [PACKAGE_NAME_FIELD, NAME_FIELD]
  })
  wiredCreatedRecord({ data, error }) {
    if (!this.createdRecordId || (!data && !error)) {
      return;
    }
    const name = (data && (getFieldValue(data, PACKAGE_NAME_FIELD) || getFieldValue(data, NAME_FIELD))) || "";
    this.finishSave(name);
  }

  // Only rendered once recordId is set: a criterion with an empty value is rejected as a configuration error.
  get contactFilter() {
    return { criteria: [{ fieldPath: "AccountId", operator: "eq", value: this.recordId }] };
  }

  handleContactChange(event) {
    this.contactId = event.detail?.recordId || undefined;
  }

  handleSave() {
    if (this.isSaving) {
      return;
    }
    const inputs = [...this.template.querySelectorAll("lightning-input-field")];
    let valid = inputs.reduce((ok, input) => input.reportValidity() && ok, true);
    const picker = this.template.querySelector("lightning-record-picker");
    if (!this.contactId) {
      picker?.reportValidity();
      valid = false;
    }
    if (!valid || !this.recordId) {
      return;
    }
    const fields = {
      [BUYING_DEALER_FIELD.fieldApiName]: this.recordId,
      [PRIMARY_CONTACT_FIELD.fieldApiName]: this.contactId
    };
    inputs.forEach((input) => {
      if (input.value !== undefined && input.value !== null && input.value !== "") {
        fields[input.fieldName] = input.value;
      }
    });
    this.isSaving = true;
    this.template.querySelector("lightning-record-edit-form").submit(fields);
  }

  handleSuccess(event) {
    // The trigger fills Package_Name__c; read it back through LDS (wiredCreatedRecord).
    this.createdRecordId = event.detail.id;
  }

  handleError() {
    // lightning-messages shows the server errors (validation rules, missing element mappings, ...).
    this.isSaving = false;
  }

  handleCancel() {
    if (!this.isSaving) {
      this.dispatchEvent(new CloseActionScreenEvent());
    }
  }

  async finishSave(name) {
    const recordId = this.createdRecordId;
    this.createdRecordId = undefined;
    let url;
    try {
      url = await this[NavigationMixin.GenerateUrl]({
        type: "standard__recordPage",
        attributes: { recordId, objectApiName: this.objectApiName, actionName: "view" }
      });
    } catch {
      url = `/lightning/r/${this.objectApiName}/${recordId}/view`;
    }
    this.dispatchEvent(
      new ShowToastEvent({
        title: "",
        message: 'Package "{0}" was created.',
        messageData: [{ url, label: name || recordId }],
        variant: "success",
        mode: "dismissible"
      })
    );
    notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
    this.dispatchEvent(new RefreshEvent());
    this.isSaving = false;
    this.dispatchEvent(new CloseActionScreenEvent());
  }
}
