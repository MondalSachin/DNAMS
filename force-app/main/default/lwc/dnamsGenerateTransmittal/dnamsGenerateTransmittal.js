import { LightningElement, api } from "lwc";
import { CloseActionScreenEvent } from "lightning/actions";
import getReadiness from "@salesforce/apex/DNAMSTransmittalPdfController.getReadiness";

/**
 * Generate Transmittal quick action on DNAMS_Package__c: checks server-side that the package is ready (passed
 * review, drafted summaries, Dealer Application extraction) and either lists what is missing or offers the PDF
 * download from the DNAMS_TransmittalPdf Visualforce page. The PDF is not saved in Salesforce.
 */
export default class DnamsGenerateTransmittal extends LightningElement {
  _recordId;
  readiness;
  isLoading = true;
  isDownloading = false;
  errorMessage;

  // Screen actions set recordId after connectedCallback, so load when it arrives.
  @api
  get recordId() {
    return this._recordId;
  }
  set recordId(value) {
    const isNew = value && value !== this._recordId;
    this._recordId = value;
    if (isNew) {
      this.load();
    }
  }

  get isReady() {
    return this.readiness?.ready === true;
  }

  get issues() {
    return this.readiness?.issues || [];
  }

  get showDownload() {
    return !this.isLoading && !this.errorMessage && this.isReady && !this.isDownloading;
  }

  async load() {
    this.isLoading = true;
    try {
      this.readiness = await getReadiness({ packageId: this.recordId });
    } catch (error) {
      this.errorMessage = error?.body?.message || error?.message || "Something went wrong.";
    } finally {
      this.isLoading = false;
    }
  }

  handleDownload() {
    // The page answers with Content-Disposition: attachment, so the browser downloads the PDF.
    window.open(this.readiness.downloadUrl, "_blank");
    this.isDownloading = true;
  }

  handleClose() {
    this.dispatchEvent(new CloseActionScreenEvent());
  }
}
