/**
 * Verified facts for one matter, assembled in bulk by FollowUpMatterSelector and consumed by the
 * rule engine, the draft builder, the facts builder (agent/prompt grounding) and the UI.
 * Contains no business thresholds and performs no queries.
 */
public with sharing class FollowUpMatterContext {
    public Matter__c matter;
    /** Most recent non-excluded treatment on or before the evaluation date. */
    public Date lastTreatmentDate;
    /** Earliest non-excluded treatment scheduled after the evaluation date. */
    public Date nextScheduledTreatmentDate;
    public Map<Id, Date> lastTreatmentByProvider = new Map<Id, Date>();
    public Map<Id, Medical_Provider__c> providers = new Map<Id, Medical_Provider__c>();
    /** All records requests on the matter (any status), oldest request first. */
    public List<Records_Request__c> requests = new List<Records_Request__c>();
    /** Most recent completed activity with the client, excluding this solution's own outbound log entries. */
    public Date lastClientContactDate;
    /** Follow-up recommendations on the matter, newest first. */
    public List<Follow_Up_Recommendation__c> history = new List<Follow_Up_Recommendation__c>();

    public FollowUpMatterContext(Matter__c matter) {
        this.matter = matter;
    }

    public Contact client() {
        return matter.Client__c == null ? null : matter.Client__r;
    }

    /** Sign-up date, falling back to the matter creation date when sign-up is not recorded. */
    public Date signUpDate() {
        if (matter.Sign_Up_Date__c != null) {
            return matter.Sign_Up_Date__c;
        }
        return matter.CreatedDate == null ? null : matter.CreatedDate.date();
    }

    /** Date the current treatment gap is measured from: last treatment, else sign-up. */
    public Date treatmentAnchor() {
        return lastTreatmentDate != null ? lastTreatmentDate : signUpDate();
    }

    /** Case manager, else matter owner when the owner is a user (queues cannot own Tasks). */
    public Id assigneeId() {
        if (matter.Case_Manager__c != null) {
            return matter.Case_Manager__c;
        }
        if (matter.OwnerId != null && matter.OwnerId.getSObjectType() == User.SObjectType) {
            return matter.OwnerId;
        }
        return null;
    }

    public String assigneeName() {
        if (matter.Case_Manager__c != null && matter.Case_Manager__r != null) {
            return matter.Case_Manager__r.Name;
        }
        if (assigneeId() != null && matter.Owner != null) {
            return matter.Owner.Name;
        }
        return null;
    }

    public List<Follow_Up_Recommendation__c> historyForKey(String dedupeKey) {
        List<Follow_Up_Recommendation__c> matches = new List<Follow_Up_Recommendation__c>();
        for (Follow_Up_Recommendation__c rec : history) {
            if (rec.Dedupe_Key__c == dedupeKey) {
                matches.add(rec);
            }
        }
        return matches;
    }

    /** Sent (or sent-then-completed) recommendations for a key, newest first. */
    public List<Follow_Up_Recommendation__c> sentForKey(String dedupeKey) {
        List<Follow_Up_Recommendation__c> sent = new List<Follow_Up_Recommendation__c>();
        for (Follow_Up_Recommendation__c rec : historyForKey(dedupeKey)) {
            if (
                rec.Sent_Date__c != null &&
                (rec.Status__c == FollowUpConstants.STATUS_SENT ||
                rec.Status__c == FollowUpConstants.STATUS_COMPLETED)
            ) {
                sent.add(rec);
            }
        }
        // History is ordered by CreatedDate; callers need the most recently SENT first.
        List<SentOrder> ordered = new List<SentOrder>();
        for (Follow_Up_Recommendation__c rec : sent) {
            ordered.add(new SentOrder(rec));
        }
        ordered.sort();
        sent.clear();
        for (SentOrder item : ordered) {
            sent.add(item.rec);
        }
        return sent;
    }

    /** Client check-ins sent on or after the given date that have not received a response. */
    public Integer unansweredSince(String dedupeKey, Date since) {
        Integer count = 0;
        for (Follow_Up_Recommendation__c rec : sentForKey(dedupeKey)) {
            if (rec.Response_Received__c != true && (since == null || rec.Sent_Date__c.date() >= since)) {
                count++;
            }
        }
        return count;
    }

    public List<Follow_Up_Recommendation__c> openRecommendations() {
        List<Follow_Up_Recommendation__c> open = new List<Follow_Up_Recommendation__c>();
        for (Follow_Up_Recommendation__c rec : history) {
            if (FollowUpConstants.OPEN_STATUSES.contains(rec.Status__c)) {
                open.add(rec);
            }
        }
        return open;
    }

    public List<Records_Request__c> outstandingRequests(Set<String> outstandingStatuses) {
        List<Records_Request__c> outstanding = new List<Records_Request__c>();
        for (Records_Request__c req : requests) {
            if (outstandingStatuses.contains(req.Status__c)) {
                outstanding.add(req);
            }
        }
        return outstanding;
    }

    public Boolean hasBillRequestFor(Id providerId, Set<String> billTypes) {
        for (Records_Request__c req : requests) {
            if (req.Medical_Provider__c == providerId && billTypes.contains(req.Request_Type__c)) {
                return true;
            }
        }
        return false;
    }

    /** Latest of: any request made, any records received, any provider follow-up sent. */
    public Date lastRecordsActivity() {
        Date latest = null;
        for (Records_Request__c req : requests) {
            latest = maxDate(latest, req.Requested_Date__c);
            latest = maxDate(latest, req.Received_Date__c);
        }
        for (Follow_Up_Recommendation__c rec : history) {
            if (rec.Recommendation_Type__c == FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP && rec.Sent_Date__c != null) {
                latest = maxDate(latest, rec.Sent_Date__c.date());
            }
        }
        return latest;
    }

    public Integer providersRequestedCount() {
        Set<Id> providerIds = new Set<Id>();
        for (Records_Request__c req : requests) {
            if (req.Medical_Provider__c != null && req.Requested_Date__c != null) {
                providerIds.add(req.Medical_Provider__c);
            }
        }
        return providerIds.size();
    }

    public Integer providersReceivedCount() {
        Set<Id> providerIds = new Set<Id>();
        for (Records_Request__c req : requests) {
            if (req.Medical_Provider__c != null && req.Received_Date__c != null) {
                providerIds.add(req.Medical_Provider__c);
            }
        }
        return providerIds.size();
    }

    public static Date maxDate(Date current, Date candidate) {
        if (candidate == null) {
            return current;
        }
        return (current == null || candidate > current) ? candidate : current;
    }

    private class SentOrder implements Comparable {
        private Follow_Up_Recommendation__c rec;
        private SentOrder(Follow_Up_Recommendation__c rec) {
            this.rec = rec;
        }
        public Integer compareTo(Object other) {
            Datetime mine = rec.Sent_Date__c;
            Datetime theirs = ((SentOrder) other).rec.Sent_Date__c;
            return mine == theirs ? 0 : (mine > theirs ? -1 : 1);
        }
    }
}
