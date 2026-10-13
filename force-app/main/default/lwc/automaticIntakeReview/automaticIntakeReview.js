import { LightningElement, wire } from 'lwc';
import getOpenIntakes from '@salesforce/apex/AutomaticIntakeReviewController.getOpenIntakes';
import { refreshApex } from '@salesforce/apex';

const COLUMNS = [
    { label: 'Intake', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'Name' }, target: '_self' } },
    { label: 'Received', fieldName: 'Received_At__c', type: 'date', typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' } },
    { label: 'Sender', fieldName: 'Sender_Email__c', type: 'email' },
    { label: 'Subject', fieldName: 'Subject__c', type: 'text', wrapText: true },
    { label: 'Type', fieldName: 'Classification__c', type: 'text' },
    { label: 'Attachments', fieldName: 'Attachment_Count__c', type: 'number' },
    { label: 'Confidence', fieldName: 'Extraction_Confidence__c', type: 'percent', typeAttributes: { maximumFractionDigits: 0 } },
    { label: 'Status', fieldName: 'Status__c', type: 'text' },
    { label: 'Review reason', fieldName: 'Review_Reason__c', type: 'text', wrapText: true }
];

export default class AutomaticIntakeReview extends LightningElement {
    columns = COLUMNS;
    rows;
    error;
    wiredResult;

    @wire(getOpenIntakes)
    wiredIntakes(result) {
        this.wiredResult = result;
        if (result.data) {
            this.rows = result.data.map((row) => ({ ...row, recordUrl: `/lightning/r/Automatic_Intake__c/${row.Id}/view` }));
            this.error = undefined;
        } else if (result.error) {
            this.rows = undefined;
            this.error = result.error;
        }
    }

    get hasRows() {
        return Array.isArray(this.rows) && this.rows.length > 0;
    }

    async handleRefresh() {
        if (this.wiredResult) {
            await refreshApex(this.wiredResult);
        }
    }
}