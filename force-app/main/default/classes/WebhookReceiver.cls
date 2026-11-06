/**
 * POST /services/apexrest/webhooks/v1/<source>
 *
 * The thinnest possible REST shell: copy the request into a Delivery, hand it to WebhookGateway, write the
 * response. Senders authenticate as an integration user (OAuth client credentials or a connected app) that
 * holds the Webhook Receiver permission set; the HMAC check is on top of that, not instead of it.
 */
@RestResource(urlMapping='/webhooks/v1/*')
@SuppressWarnings('PMD.AvoidGlobalModifier') // Apex REST resources must be global
global with sharing class WebhookReceiver {
    @HttpPost
    global static void receive() {
        RestRequest request = RestContext.request;
        RestResponse response = RestContext.response;

        WebhookGateway.Delivery delivery = new WebhookGateway.Delivery();
        delivery.sourceName = lastSegment(request.requestURI);
        delivery.body = request.requestBody;
        delivery.headers = request.headers == null ? new Map<String, String>() : request.headers;

        WebhookGateway.Response result = WebhookGateway.receive(delivery);
        response.statusCode = result.statusCode;
        response.addHeader('Content-Type', 'application/json');
        response.responseBody = Blob.valueOf(JSON.serialize(result.body));
    }

    /** "/webhooks/v1/github" or "/webhooks/v1/github/" -> "github". */
    @TestVisible
    private static String lastSegment(String uri) {
        if (uri == null) {
            return null;
        }
        String trimmed = uri.removeEnd('/');
        return trimmed.substring(trimmed.lastIndexOf('/') + 1);
    }
}
