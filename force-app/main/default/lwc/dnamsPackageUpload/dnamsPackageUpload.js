import { LightningElement } from "lwc";
import isGuest from "@salesforce/user/isGuest";
import getPackage from "@salesforce/apex/DNAMS_GuestUploadController.getPackage";
import submitPackage from "@salesforce/apex/DNAMS_GuestUploadController.submitPackage";
import removeDocument from "@salesforce/apex/DNAMS_GuestUploadController.removeDocument";

const UPLOAD_FIELD = "DNAMS_Upload_Token_fileupload__c";

/**
 * Public upload page for one package, opened from the emailed link (?token=...).
 * Works for site guests and logged-in users; all access goes through DNAMS_GuestUploadController.
 */
export default class DnamsPackageUpload extends LightningElement {
  token;
  pkg;
  isLoading = false;
  errorMessage;
  uploadField = UPLOAD_FIELD;

  connectedCallback() {
    this.token = new URLSearchParams(window.location.search).get("token");
    if (this.token) {
      this.load();
    }
  }

  get hasToken() {
    return Boolean(this.token);
  }

  get showNoLinkMessage() {
    return !this.token && isGuest;
  }

  get elements() {
    if (!this.pkg) {
      return [];
    }
    return this.pkg.elements.map((element, index) => ({
      ...element,
      position: index + 1,
      uploadValue: `${element.id}:${this.token}`,
      // Required elements, and any element the reviewer flagged, can take uploads while editable.
      canUpload: this.pkg.isEditable,
      canRemove: this.pkg.isEditable,
      rowClass:
        (element.isRequired && element.documents.length === 0) || element.issue
          ? "slds-hint-parent dnams-missing"
          : "slds-hint-parent"
    }));
  }

  get requiredProgress() {
    const required = this.elements.filter((e) => e.isRequired);
    const done = required.filter((e) => e.documents.length > 0).length;
    return `${done} of ${required.length} required elements have documents`;
  }

  async load() {
    await this.run(async () => {
      this.pkg = await getPackage({ token: this.token });
    });
  }

  handleUploadFinished() {
    this.load();
  }

  async handleRemove(event) {
    const contentDocumentId = event.currentTarget.dataset.id;
    await this.run(async () => {
      await removeDocument({ token: this.token, contentDocumentId });
      this.pkg = await getPackage({ token: this.token });
    });
  }

  async handleSubmit() {
    await this.run(async () => {
      await submitPackage({ token: this.token });
      this.pkg = await getPackage({ token: this.token });
    });
  }

  async run(action) {
    this.isLoading = true;
    this.errorMessage = undefined;
    try {
      await action();
    } catch (error) {
      this.errorMessage =
        error?.body?.message || error?.message || "Something went wrong.";
    } finally {
      this.isLoading = false;
    }
  }
}