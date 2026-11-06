/**
 * The Reprocess button on a Webhook Event, and the same action for any Flow: re-runs the handler for a Failed
 * event (after the handler was fixed), an Ignored one (after a handler was registered), or one stuck in
 * Received, now, in this transaction. Everything else is reported as skipped.
 */
public without sharing class WebhookReprocessAction {
    public class Request {
        @InvocableVariable(label='Webhook Event Id' required=true)
        public Id eventId;
    }

    public class Result {
        @InvocableVariable(label='Outcome' description='Processed, Failed, Ignored, or Skipped (<status>).')
        public String outcome;
    }

    @InvocableMethod(
        label='Reprocess webhook events'
        description='Re-runs the handler for Failed, Ignored, or stuck Received events, now. Returns Processed, Failed, Ignored, or Skipped (<status>) per event.'
        category='Webhook Events'
    )
    public static List<Result> reprocess(List<Request> requests) {
        List<Id> eventIds = new List<Id>();
        for (Request request : requests) {
            eventIds.add(request.eventId);
        }
        Map<Id, String> before = new Map<Id, String>();
        for (Webhook_Event__c event : [SELECT Id, Status__c FROM Webhook_Event__c WHERE Id IN :eventIds]) {
            before.put(event.Id, event.Status__c);
        }
        Map<Id, String> outcomes = WebhookDispatcher.reprocess(eventIds);
        List<Result> results = new List<Result>();
        for (Id eventId : eventIds) {
            Result result = new Result();
            if (outcomes.containsKey(eventId)) {
                result.outcome = outcomes.get(eventId);
            } else {
                result.outcome = 'Skipped (' + (before.containsKey(eventId) ? before.get(eventId) : 'not found') + ')';
            }
            results.add(result);
        }
        return results;
    }
}
