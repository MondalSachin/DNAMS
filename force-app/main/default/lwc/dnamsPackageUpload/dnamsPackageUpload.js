import { LightningElement } from "lwc";
import isGuest from "@salesforce/user/isGuest";
import getPackage from "@salesforce/apex/DNAMS_GuestUploadController.getPackage";
import submitPackage from "@salesforce/apex/DNAMS_GuestUploadController.submitPackage";
import removeDocument from "@salesforce/apex/DNAMS_GuestUploadController.removeDocument";

const UPLOAD_FIELD = "DNAMS_Upload_Token_fileupload__c";
const RING_RADIUS = 24;
const RING_LENGTH = 2 * Math.PI * RING_RADIUS;

const plural = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;

/**
 * Public upload page for one package, opened from the emailed link (?token=...).
 * Works for site guests and logged-in users; all access goes through DNAMS_GuestUploadController.
 * Layout: navy band, package card with the element table (fixed-height two-column file cards),
 * a right column with progress and the two steps, and a footer.
 * Returned packages show only the flagged elements. Once submitted the link is closed: the server
 * returns isClosed and no package details.
 */
export default class DnamsPackageUpload extends LightningElement {
  token;
  pkg;
  isLoading = false;
  loadError;
  actionError;
  uploadField = UPLOAD_FIELD;
  acceptedFormats = [".pdf"];
  changedIds = new Set();
  openTipId;
  showConfirm = false;
  toastMessage;
  toastTimer;

  connectedCallback() {
    this.token = new URLSearchParams(window.location.search).get("token");
    if (this.token) {
      this.load();
    }
  }

  disconnectedCallback() {
    clearTimeout(this.toastTimer);
  }

  // ---------------------------------------------------------------- page state

  get hasToken() {
    return Boolean(this.token);
  }

  /** Logged-in users without a token see the sender component instead; render nothing for them. */
  get showPage() {
    return this.hasToken || isGuest;
  }

  get showNoLink() {
    return !this.hasToken;
  }

  get showInvalid() {
    return this.hasToken && !this.pkg && Boolean(this.loadError);
  }

  get showLoading() {
    return this.hasToken && !this.pkg && !this.loadError;
  }

  get showClosed() {
    return Boolean(this.pkg?.isClosed);
  }

  get showPackage() {
    return Boolean(this.pkg) && !this.pkg.isClosed;
  }

  get isReturned() {
    return Boolean(this.pkg?.isReturned);
  }

  get statusLabel() {
    return this.isReturned ? "Returned" : "In Progress";
  }

  get statusClass() {
    return this.isReturned ? "status red" : "status blue";
  }

  get bandTitle() {
    if (this.showClosed) return "Thanks, we have your documents";
    if (this.showPackage && this.isReturned) return "Your package needs a few corrections";
    if (this.showPackage) return "Upload your package documents";
    return "Harbor Motors Dealer Portal";
  }

  get bandSubtitle() {
    if (this.showClosed) return "This link is now closed. We'll email you a new link if anything else is needed.";
    if (this.showPackage && this.isReturned) return "Fix the elements marked in red, then resubmit. Everything else stays as it is.";
    if (this.showPackage) return "Add one or more PDFs to each required element, then submit the package to Harbor Motors.";
    return "Upload the documents for your dealer packages.";
  }

  // ---------------------------------------------------------------- elements

  get allElements() {
    if (!this.pkg?.elements) {
      return [];
    }
    return this.pkg.elements.map((element) => {
      const documents = element.documents || [];
      const changed = this.changedIds.has(element.id);
      const flagged = this.isReturned && Boolean(element.issue);
      let tone = "";
      if (flagged) {
        tone = changed ? "blue" : "red";
      } else if (documents.length) {
        tone = "green";
      } else if (element.isRequired) {
        tone = "amber";
      }
      return {
        ...element,
        documents: documents.map((doc) => ({ ...doc, key: doc.id, removeLabel: `Remove ${doc.name}` })),
        hasFiles: documents.length > 0,
        countLabel: documents.length ? plural(documents.length, "file") : element.isRequired ? "Required" : "Optional",
        flagged,
        changed,
        showFix: flagged && !changed,
        showFixed: flagged && changed,
        rowClass: `row ${tone}`,
        uploadValue: `${element.id}:${this.token}`,
        tipId: `tip-${element.id}`,
        infoLabel: `Instructions for ${element.name}`,
        filesLabel: `Files for ${element.name}`,
        tipExpanded: this.openTipId === element.id ? "true" : "false"
      };
    });
  }

  /** Returned packages show only the elements that need attention. */
  get elements() {
    const all = this.allElements;
    return this.isReturned ? all.filter((e) => e.flagged) : all;
  }

  get missingRequired() {
    return this.allElements.filter((e) => e.isRequired && !e.hasFiles);
  }

  get submitDisabled() {
    return this.isLoading || this.missingRequired.length > 0;
  }

  get submitLabel() {
    return this.isReturned ? "Resubmit Package" : "Submit Package";
  }

  get confirmText() {
    return `Are you sure you want to ${this.isReturned ? "resubmit" : "submit"} the package? This link closes after you submit.`;
  }

  get openIssueCount() {
    return this.elements.filter((e) => e.showFix).length;
  }

  get returnedNote() {
    const open = this.openIssueCount;
    return open
      ? `${open} ${open === 1 ? "element needs" : "elements need"} changes before you resubmit.`
      : "All corrections made. Resubmit the package when you're ready.";
  }

  get returnedNoteClass() {
    return this.openIssueCount ? "note red" : "note green";
  }

  get returnedNoteDetail() {
    return this.openIssueCount ? "Each one is marked below." : "";
  }

  // ---------------------------------------------------------------- right column

  get progress() {
    let done;
    let total;
    if (this.isReturned) {
      const flagged = this.elements;
      total = flagged.length;
      done = flagged.filter((e) => e.changed).length;
    } else {
      const required = this.allElements.filter((e) => e.isRequired);
      total = required.length;
      done = required.filter((e) => e.hasFiles).length;
    }
    return { done, total, complete: total > 0 && done === total };
  }

  get panelTitle() {
    return this.isReturned ? "Corrections" : "Completed";
  }

  get ringText() {
    return `${this.progress.done}/${this.progress.total}`;
  }

  get ringDash() {
    const { done, total } = this.progress;
    const share = total ? done / total : 0;
    return `${RING_LENGTH * share} ${RING_LENGTH}`;
  }

  get ringClass() {
    if (this.progress.complete) return "ring-value green";
    return this.isReturned ? "ring-value red" : "ring-value blue";
  }

  get progressHeadline() {
    const { done, total, complete } = this.progress;
    if (this.isReturned) {
      return complete ? "All corrections made" : `${total - done} to correct`;
    }
    return complete ? "Ready to submit" : `${total - done} still needed`;
  }

  get progressDetail() {
    const { done, total } = this.progress;
    return this.isReturned ? `${done} of ${total} corrections made` : `${done} of ${total} required elements have files`;
  }

  get step1Class() {
    return this.progress.complete ? "done" : "now";
  }

  get step2Class() {
    return this.progress.complete ? "now" : "todo";
  }

  get step1Title() {
    return this.isReturned ? "Fix the marked elements" : "Upload documents";
  }

  get step1Detail() {
    return this.isReturned ? "Upload the right files" : "One or more PDFs per element";
  }

  get step2Title() {
    return this.isReturned ? "Resubmit the package" : "Submit the package";
  }

  // ---------------------------------------------------------------- actions

  async load() {
    this.isLoading = true;
    try {
      this.pkg = await getPackage({ token: this.token });
      this.loadError = undefined;
    } catch (error) {
      this.pkg = undefined;
      this.loadError = this.message(error);
    } finally {
      this.isLoading = false;
    }
  }

  async handleUploadFinished(event) {
    const elementId = event.target.dataset.id;
    const count = event.detail?.files?.length || 0;
    this.markChanged(elementId);
    await this.load();
    const element = this.allElements.find((e) => e.id === elementId);
    this.toast(count > 1 ? `Uploaded ${count} files to ${element?.name}.` : `Uploaded to ${element?.name}.`);
  }

  async handleRemove(event) {
    const { id, element } = event.currentTarget.dataset;
    const name = event.currentTarget.dataset.name;
    await this.run(async () => {
      await removeDocument({ token: this.token, contentDocumentId: id });
      this.markChanged(element);
      this.pkg = await getPackage({ token: this.token });
      this.toast(`Removed ${name}.`);
    });
  }

  handleSubmitClick() {
    this.showConfirm = true;
  }

  handleCancelConfirm() {
    this.showConfirm = false;
  }

  handleConfirmKeydown(event) {
    if (event.key === "Escape") {
      this.showConfirm = false;
    }
  }

  async handleConfirmSubmit() {
    this.showConfirm = false;
    await this.run(async () => {
      await submitPackage({ token: this.token });
      this.pkg = await getPackage({ token: this.token });
    });
  }

  handleInfo(event) {
    const id = event.currentTarget.dataset.id;
    this.openTipId = this.openTipId === id ? undefined : id;
  }

  renderedCallback() {
    if (this.showConfirm) {
      const ok = this.template.querySelector(".dialog .btn-submit");
      if (ok && this.template.activeElement !== ok && !this.confirmFocused) {
        ok.focus();
        this.confirmFocused = true;
      }
    } else {
      this.confirmFocused = false;
    }
  }

  markChanged(elementId) {
    if (elementId) {
      this.changedIds = new Set(this.changedIds).add(elementId);
    }
  }

  toast(message) {
    this.toastMessage = message;
    clearTimeout(this.toastTimer);
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this.toastTimer = setTimeout(() => {
      this.toastMessage = undefined;
    }, 4000);
  }

  async run(action) {
    this.isLoading = true;
    this.actionError = undefined;
    try {
      await action();
    } catch (error) {
      this.actionError = this.message(error);
    } finally {
      this.isLoading = false;
    }
  }

  message(error) {
    return error?.body?.message || error?.message || "Something went wrong. Please try again.";
  }
}
