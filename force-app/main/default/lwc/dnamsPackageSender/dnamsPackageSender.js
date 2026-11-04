import { LightningElement } from "lwc";
import isGuest from "@salesforce/user/isGuest";
import getUnsubmittedPackages from "@salesforce/apex/DNAMS_PackageController.getUnsubmittedPackages";
import sendUploadLink from "@salesforce/apex/DNAMS_PackageController.sendUploadLink";

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/**
 * Home-page section for logged-in users: packages not yet submitted, each with a field for the
 * recipient and a Send Link button. Renders nothing for site guests or on an upload link page.
 */
export default class DnamsPackageSender extends LightningElement {
  // Hidden for guests and on upload links (?token=...): a link shows only its own package.
  isVisible = !isGuest && !new URLSearchParams(window.location.search).get("token");
  packages = [];
  recipients = {};
  sendingId;
  isLoading = false;
  errorMessage;
  successMessage;

  connectedCallback() {
    if (this.isVisible) {
      this.load();
    }
  }

  get rows() {
    return this.packages.map((pkg) => ({
      ...pkg,
      recipient: this.recipients[pkg.id] ?? "",
      isSending: this.sendingId === pkg.id,
      lastSent: pkg.lastSentTo
        ? `${pkg.lastSentTo} (${new Date(pkg.lastSentAt).toLocaleString()})`
        : "Not sent yet"
    }));
  }

  get hasPackages() {
    return this.packages.length > 0;
  }

  async load() {
    this.isLoading = true;
    try {
      this.packages = await getUnsubmittedPackages();
    } catch (error) {
      this.showError(error);
    } finally {
      this.isLoading = false;
    }
  }

  handleRecipientChange(event) {
    this.recipients = {
      ...this.recipients,
      [event.target.dataset.id]: event.target.value.trim()
    };
  }

  async handleSend(event) {
    const packageId = event.currentTarget.dataset.id;
    const recipient = this.recipients[packageId];
    this.errorMessage = undefined;
    this.successMessage = undefined;
    if (!recipient || !EMAIL_PATTERN.test(recipient)) {
      this.errorMessage = "Enter a valid email address before sending.";
      return;
    }
    this.sendingId = packageId;
    try {
      await sendUploadLink({ packageId, recipientEmail: recipient });
      const pkg = this.packages.find((p) => p.id === packageId);
      this.successMessage = `Upload link for ${pkg.packageNumber} sent to ${recipient}.`;
      await this.load();
    } catch (error) {
      this.showError(error);
    } finally {
      this.sendingId = undefined;
    }
  }

  showError(error) {
    this.errorMessage =
      error?.body?.message || error?.message || "Something went wrong.";
  }
}