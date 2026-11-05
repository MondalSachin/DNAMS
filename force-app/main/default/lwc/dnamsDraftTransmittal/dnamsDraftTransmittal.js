import { LightningElement, api } from "lwc";
import { CloseActionScreenEvent } from "lightning/actions";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { RefreshEvent } from "lightning/refresh";
import { notifyRecordUpdateAvailable } from "lightning/uiRecordApi";
import getDraftState from "@salesforce/apex/DNAMSTransmittalController.getDraftState";
import draftTransmittal from "@salesforce/apex/DNAMSTransmittalController.draftTransmittal";

// Scenarios that ask the RMR to confirm (No/Yes); every other scenario only informs (Close).
const CONFIRM_SCENARIOS = new Set(["DRAFTED", "RULES_FAILED", "READY"]);

/**
 * Draft AI Transmittal quick action on DNAMS_Package__c: shows the drafting scenario for the latest AI review run
 * and, after the RMR confirms, drafts the Ownership and Executive summaries.
 */
export default class DnamsDraftTransmittal extends LightningElement {
  _recordId;
  state;
  isLoading = true;
  loadingText = "Loading";
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

  get isConfirm() {
    return CONFIRM_SCENARIOS.has(this.state?.scenario);
  }

  async load() {
    this.isLoading = true;
    try {
      this.state = await getDraftState({ packageId: this.recordId });
    } catch (error) {
      this.errorMessage = this.reduceError(error);
    } finally {
      this.isLoading = false;
    }
  }

  async handleYes() {
    this.loadingText = "Drafting transmittal summaries…";
    this.isLoading = true;
    try {
      const outcome = await draftTransmittal({ packageId: this.recordId });
      this.toast(outcome.success ? "success" : "error", outcome.message);
    } catch (error) {
      this.toast("error", this.reduceError(error));
    }
    // Refresh even after a failure: the run's transmittal status may have changed.
    notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
    this.dispatchEvent(new RefreshEvent());
    this.handleClose();
  }

  handleClose() {
    this.dispatchEvent(new CloseActionScreenEvent());
  }

  toast(variant, message) {
    this.dispatchEvent(
      new ShowToastEvent({
        title: variant === "success" ? "Transmittal drafted" : "Transmittal not drafted",
        message,
        variant
      })
    );
  }

  reduceError(error) {
    return error?.body?.message || error?.message || "Something went wrong.";
  }
}
