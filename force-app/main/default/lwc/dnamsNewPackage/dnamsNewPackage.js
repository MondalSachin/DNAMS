import { LightningElement, wire } from "lwc";
import { CurrentPageReference, NavigationMixin } from "lightning/navigation";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { getRecord, getFieldValue } from "lightning/uiRecordApi";
import { decodeDefaultFieldValues } from "lightning/pageReferenceUtils";
import PACKAGE_OBJECT from "@salesforce/schema/DNAMS_Package__c";
import NAME_FIELD from "@salesforce/schema/DNAMS_Package__c.Name";
import PACKAGE_NAME_FIELD from "@salesforce/schema/DNAMS_Package__c.Package_Name__c";
import TYPE_FIELD from "@salesforce/schema/DNAMS_Package__c.Type__c";
import BUYING_DEALER_FIELD from "@salesforce/schema/DNAMS_Package__c.Buying_Dealer__c";
import PRIMARY_CONTACT_FIELD from "@salesforce/schema/DNAMS_Package__c.Primary_Contact__c";
import SELLING_DEALER_FIELD from "@salesforce/schema/DNAMS_Package__c.Selling_Dealer__c";

/**
 * New Package form, used as the New action override of DNAMS_Package__c (through the Aura wrapper
 * dnamsNewPackageOverride). After saving it toasts 'Package "<Package Name>" was created.' using the
 * Package_Name__c value that the before-insert trigger computes, then opens the new record.
 */
export default class DnamsNewPackage extends NavigationMixin(LightningElement) {
  objectApiName = PACKAGE_OBJECT.objectApiName;
  pageRef;
  defaults = {};
  isSaving = false;
  createdRecordId;
  formKey = 0;
  hasFocused = false;
  dealerId;
  contactId;
  typeField = TYPE_FIELD.fieldApiName;
  buyingDealerField = BUYING_DEALER_FIELD.fieldApiName;
  sellingDealerField = SELLING_DEALER_FIELD.fieldApiName;
  contactDisplayInfo = { additionalFields: ["Email"] };

  @wire(CurrentPageReference)
  wiredPageRef(pageRef) {
    // The override can stay cached while the user moves on, so only react to this object's New page.
    const attributes = pageRef?.attributes;
    if (
      pageRef?.type !== "standard__objectPage" ||
      attributes?.actionName !== "new" ||
      attributes?.objectApiName !== this.objectApiName
    ) {
      return;
    }
    this.pageRef = pageRef;
    this.defaults = this.readDefaults(pageRef);
    this.isSaving = false;
    this.createdRecordId = undefined;
    this.formKey += 1;
    this.hasFocused = false;
    this.dealerId = this.defaults[BUYING_DEALER_FIELD.fieldApiName];
    this.contactId = this.defaults[PRIMARY_CONTACT_FIELD.fieldApiName];
  }

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

  get typeKey() {
    return `${this.formKey}-type`;
  }

  get dealerKey() {
    return `${this.formKey}-dealer`;
  }

  get sellingKey() {
    return `${this.formKey}-selling`;
  }

  // A new key re-creates the picker, which clears its selection when the dealer changes.
  get contactKey() {
    return `${this.formKey}-contact-${this.dealerId || "none"}`;
  }

  get noDealer() {
    return !this.dealerId;
  }

  get contactPlaceholder() {
    return this.dealerId ? "Search Contacts..." : "Select the Dealer / Buying Dealer first";
  }

  // No filter until a dealer is chosen: a criterion with an empty value is rejected as a configuration error.
  get contactFilter() {
    return this.dealerId ? { criteria: [{ fieldPath: "AccountId", operator: "eq", value: this.dealerId }] } : undefined;
  }

  renderedCallback() {
    if (!this.hasFocused) {
      const dialog = this.template.querySelector("section");
      if (dialog) {
        this.hasFocused = true;
        dialog.focus();
      }
    }
  }

  handleDealerChange(event) {
    const value = event.detail?.value;
    const dealerId = (Array.isArray(value) ? value[0] : value) || undefined;
    if (dealerId !== this.dealerId) {
      this.dealerId = dealerId;
      this.contactId = undefined;
    }
  }

  handleContactChange(event) {
    this.contactId = event.detail?.recordId || undefined;
  }

  handleSubmit(event) {
    event.preventDefault();
    const picker = this.template.querySelector("lightning-record-picker");
    if (!this.contactId) {
      picker?.reportValidity();
      return;
    }
    const fields = { ...event.detail.fields, [PRIMARY_CONTACT_FIELD.fieldApiName]: this.contactId };
    this.isSaving = true;
    this.template.querySelector("lightning-record-edit-form").submit(fields);
  }

  handleSuccess(event) {
    const record = event.detail;
    const packageName = record?.fields?.[PACKAGE_NAME_FIELD.fieldApiName]?.value;
    if (packageName) {
      this.createdRecordId = record.id;
      this.finishSave(packageName);
      return;
    }
    // The trigger fills Package_Name__c; read it back through LDS (wiredCreatedRecord).
    this.createdRecordId = record.id;
  }

  handleError() {
    // lightning-messages shows the server errors (e.g. validation rules); bring them into view.
    this.isSaving = false;
    const body = this.template.querySelector(".slds-modal__content");
    if (body) {
      body.scrollTop = 0;
    }
  }

  handleCancel() {
    if (this.isSaving) {
      return;
    }
    this[NavigationMixin.Navigate](this.returnPageRef(), true);
  }

  handleKeydown(event) {
    if (event.key === "Escape" && !event.defaultPrevented) {
      event.stopPropagation();
      this.handleCancel();
    }
  }

  finishSave(name) {
    const recordId = this.createdRecordId;
    this.createdRecordId = undefined;
    this.isSaving = false;
    this.dispatchEvent(
      new ShowToastEvent({
        title: `Package "${name || recordId}" was created.`,
        variant: "success"
      })
    );
    this[NavigationMixin.Navigate](
      {
        type: "standard__recordPage",
        attributes: { recordId, objectApiName: this.objectApiName, actionName: "view" }
      },
      true
    );
  }

  // Where the user came from: LEX passes it as inContextOfRef ("1." + base64 page reference) or as
  // backgroundContext (a URL path). Falls back to the Packages list.
  returnPageRef() {
    const state = this.pageRef?.state || {};
    if (state.inContextOfRef) {
      try {
        const encoded = state.inContextOfRef.startsWith("1.")
          ? state.inContextOfRef.substring(2)
          : state.inContextOfRef;
        const ref = JSON.parse(window.atob(encoded));
        if (ref?.type) {
          return ref;
        }
      } catch {
        // Unreadable context: use the fallback below.
      }
    }
    if (state.backgroundContext) {
      return { type: "standard__webPage", attributes: { url: state.backgroundContext } };
    }
    return {
      type: "standard__objectPage",
      attributes: { objectApiName: this.objectApiName, actionName: "home" }
    };
  }

  readDefaults(pageRef) {
    const encoded = pageRef?.state?.defaultFieldValues;
    if (!encoded) {
      return {};
    }
    try {
      return decodeDefaultFieldValues(encoded);
    } catch {
      return {};
    }
  }
}
