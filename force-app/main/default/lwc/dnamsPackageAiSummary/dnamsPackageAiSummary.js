import { LightningElement, api, wire } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { getRecord } from "lightning/uiRecordApi";
import { refreshApex } from "@salesforce/apex";
import getAiSummary from "@salesforce/apex/DNAMS_PackageInsightsController.getAiSummary";
import LAST_MODIFIED from "@salesforce/schema/DNAMS_Package__c.LastModifiedDate";

/** Package record page card: the structured AI summary plus the latest review run. */
export default class DnamsPackageAiSummary extends NavigationMixin(LightningElement) {
    @api recordId;
    view;
    error;
    wiredResult;
    lastModified;

    @wire(getAiSummary, { packageId: "$recordId" })
    wiredSummary(result) {
        this.wiredResult = result;
        this.view = result.data;
        this.error = result.error ? (result.error.body?.message || "The summary could not be loaded.") : undefined;
    }

    // Refresh when the package changes (a run writes Health, Status and the summary onto it).
    @wire(getRecord, { recordId: "$recordId", fields: [LAST_MODIFIED] })
    wiredRecord({ data }) {
        const stamp = data?.fields?.LastModifiedDate?.value;
        if (stamp && this.lastModified && stamp !== this.lastModified) {
            this.handleRefresh();
        }
        this.lastModified = stamp || this.lastModified;
    }

    get hasRun() {
        return Boolean(this.view?.runId);
    }

    get passRateLabel() {
        return this.view?.passRate === null || this.view?.passRate === undefined ? null : `${this.view.passRate}% rules passed`;
    }

    handleRefresh() {
        return refreshApex(this.wiredResult);
    }

    openRun(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: "standard__recordPage",
            attributes: { recordId: this.view.runId, actionName: "view" }
        });
    }
}
