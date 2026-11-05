import { LightningElement, api, wire } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { getRecord } from "lightning/uiRecordApi";
import { refreshApex } from "@salesforce/apex";
import getDocuments from "@salesforce/apex/DNAMS_PackageInsightsController.getDocuments";
import LAST_MODIFIED from "@salesforce/schema/DNAMS_Package__c.LastModifiedDate";

const ICONS = {
    pdf: "doctype:pdf",
    doc: "doctype:word",
    docx: "doctype:word",
    xls: "doctype:excel",
    xlsx: "doctype:excel",
    csv: "doctype:csv",
    ppt: "doctype:ppt",
    pptx: "doctype:ppt",
    png: "doctype:image",
    jpg: "doctype:image",
    jpeg: "doctype:image",
    txt: "doctype:txt"
};
function formatSize(bytes) {
    if (!bytes && bytes !== 0) {
        return "";
    }
    if (bytes < 1024) {
        return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
        return `${(bytes / 1024).toFixed(0)} KB`;
    }
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/** Documents tab: the package's files grouped by element, or as one list, with their classification result. */
export default class DnamsPackageDocuments extends NavigationMixin(LightningElement) {
    @api recordId;
    groups;
    error;
    wiredResult;
    lastModified;
    view = "grouped";

    @wire(getDocuments, { packageId: "$recordId" })
    wiredDocuments(result) {
        this.wiredResult = result;
        this.error = result.error ? (result.error.body?.message || "Documents could not be loaded.") : undefined;
        this.groups = result.data ? result.data.map((group) => this.decorateGroup(group)) : undefined;
    }

    @wire(getRecord, { recordId: "$recordId", fields: [LAST_MODIFIED] })
    wiredRecord({ data }) {
        const stamp = data?.fields?.LastModifiedDate?.value;
        if (stamp && this.lastModified && stamp !== this.lastModified) {
            this.handleRefresh();
        }
        this.lastModified = stamp || this.lastModified;
    }

    decorateGroup(group) {
        const files = group.files.map((file) => ({
            ...file,
            key: `${group.elementId}-${file.contentDocumentId}`,
            elementName: group.name,
            icon: ICONS[(file.extension || "").toLowerCase()] || "doctype:unknown",
            sizeLabel: formatSize(file.size)
        }));
        return {
            ...group,
            files,
            hasFiles: files.length > 0,
            sectionClass: files.length === 0 && group.required ? "group group_missing" : "group"
        };
    }

    get isGrouped() {
        return this.view === "grouped";
    }

    get groupedVariant() {
        return this.isGrouped ? "brand" : "neutral";
    }

    get listVariant() {
        return this.isGrouped ? "neutral" : "brand";
    }

    get allFiles() {
        return (this.groups || []).flatMap((group) => group.files);
    }

    get totalLabel() {
        const files = this.allFiles.length;
        const elements = (this.groups || []).filter((group) => group.hasFiles).length;
        return `${files} file${files === 1 ? "" : "s"} on ${elements} element${elements === 1 ? "" : "s"}`;
    }

    get hasAnyFiles() {
        return this.allFiles.length > 0;
    }

    showGrouped() {
        this.view = "grouped";
    }

    showList() {
        this.view = "list";
    }

    handleRefresh() {
        return refreshApex(this.wiredResult);
    }

    preview(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: "standard__namedPage",
            attributes: { pageName: "filePreview" },
            state: { selectedRecordId: event.currentTarget.dataset.id }
        });
    }

    openElement(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: "standard__recordPage",
            attributes: { recordId: event.currentTarget.dataset.id, actionName: "view" }
        });
    }
}
