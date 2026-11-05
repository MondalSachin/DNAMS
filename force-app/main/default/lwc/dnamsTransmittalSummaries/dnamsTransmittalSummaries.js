import { LightningElement, api, wire } from "lwc";
import { getRecord, getFieldValue } from "lightning/uiRecordApi";
import { getObjectInfo } from "lightning/uiObjectInfoApi";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import PACKAGE_OBJECT from "@salesforce/schema/DNAMS_Package__c";
import OWNERSHIP_FIELD from "@salesforce/schema/DNAMS_Package__c.Ownership_Summary__c";
import EXECUTIVE_FIELD from "@salesforce/schema/DNAMS_Package__c.Executive_Summary__c";

/**
 * Transmittal tab on DNAMS_Package__c: shows the Ownership and Executive summaries in fixed-height boxes that scroll
 * when the drafted text is long (it is never trimmed), with inline editing for users who can edit the fields.
 */
export default class DnamsTransmittalSummaries extends LightningElement {
  @api recordId;
  objectApiName = PACKAGE_OBJECT.objectApiName;
  ownershipField = OWNERSHIP_FIELD.fieldApiName;
  executiveField = EXECUTIVE_FIELD.fieldApiName;
  isEditing = false;
  isSaving = false;
  canEdit = false;

  @wire(getRecord, { recordId: "$recordId", fields: [OWNERSHIP_FIELD, EXECUTIVE_FIELD] })
  record;

  @wire(getObjectInfo, { objectApiName: PACKAGE_OBJECT })
  wiredObjectInfo({ data }) {
    const fields = data?.fields ?? {};
    this.canEdit = Boolean(fields[this.ownershipField]?.updateable || fields[this.executiveField]?.updateable);
  }

  get ownership() {
    return getFieldValue(this.record.data, OWNERSHIP_FIELD);
  }

  get executive() {
    return getFieldValue(this.record.data, EXECUTIVE_FIELD);
  }

  get showEditButton() {
    return this.canEdit && !this.isEditing;
  }

  handleEdit() {
    this.isEditing = true;
  }

  handleCancel() {
    this.isEditing = false;
  }

  handleSubmit() {
    this.isSaving = true;
  }

  // The record wire refreshes from the saved record, so only the mode changes here.
  handleSuccess() {
    this.isSaving = false;
    this.isEditing = false;
    this.dispatchEvent(new ShowToastEvent({ title: "Transmittal summaries saved", variant: "success" }));
  }

  handleError() {
    this.isSaving = false;
  }
}
