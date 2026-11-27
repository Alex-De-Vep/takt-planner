using System.Net;
using System.Text;
using System.Text.Json;
using Takt.Core.Calendar;
using Xunit;

namespace Takt.Core.Tests;

public sealed class CalendarAccountsTests
{
    private static CalendarAuthorization Google => new(
        new(CalendarAccountKind.Google, "fixture.apps.googleusercontent.com", "fixture-desktop-client"),
        "fixture-access", "fixture-refresh", DateTimeOffset.UtcNow.AddHours(1));
    private static CalendarAuthorization Outlook => new(
        new(CalendarAccountKind.Outlook, "8cabd20a-32a1-4abc-a8d5-588b15c8b5de"),
        "fixture-access", "fixture-refresh", DateTimeOffset.UtcNow.AddHours(1));
    private static ConnectedCalendar Calendar(CalendarAccountKind kind) => new(Guid.NewGuid(), kind,
        new(kind == CalendarAccountKind.Google ? "fixture@example.test" : "calendar-id", "Fixture", true, true, "UTC"));

    private const string GoogleEvent = """
        {
          "id": "fixture-event", "etag": "\"one\"", "summary": "Original",
          "organizer": { "self": true },
          "start": { "date": "2026-11-27" }, "end": { "date": "2026-11-29" }
        }
        """;
    private const string OutlookEvent = """
        {
          "id": "fixture-outlook-event", "@odata.etag": "W/\"one\"", "subject": "Review",
          "isOrganizer": true, "isAllDay": false, "type": "singleInstance", "bodyPreview": "Preview",
          "originalStartTimeZone": "Pacific Standard Time", "location": { "displayName": "Main room" },
          "locations": [{ "displayName": "Main room" }, { "displayName": "Side room" }],
          "start": { "dateTime": "2026-11-27T17:15:30", "timeZone": "UTC" },
          "end": { "dateTime": "2026-11-27T18:15:30", "timeZone": "UTC" }
        }
        """;

    [Fact]
    public async Task GoogleAllDayPatchUsesExclusiveEndAndTheReviewedVersion()
    {
        int writes = 0;
        var calendar = Calendar(CalendarAccountKind.Google);
        using var transport = new HttpClient(new Fixture(async request =>
        {
            Assert.Equal("www.googleapis.com", request.RequestUri!.Host);
            Assert.EndsWith("/events/fixture-event", request.RequestUri.AbsolutePath);
            Assert.Equal("fixture-access", request.Headers.Authorization?.Parameter);
            if (request.Method == HttpMethod.Get) return Reply(GoogleEvent);

            Assert.Equal(HttpMethod.Patch, request.Method);
            Assert.Contains("sendUpdates=all", request.RequestUri.Query);
            Assert.Equal("\"one\"", Assert.Single(request.Headers.IfMatch).Tag);
            using var json = JsonDocument.Parse(await request.Content!.ReadAsStringAsync());
            Assert.Equal("2026-11-27", json.RootElement.GetProperty("start").GetProperty("date").GetString());
            Assert.Equal("2026-11-30", json.RootElement.GetProperty("end").GetProperty("date").GetString());
            Assert.False(json.RootElement.TryGetProperty("attendees", out _));
            Assert.False(json.RootElement.TryGetProperty("reminders", out _));
            writes++;
            return Reply(GoogleEvent);
        }));
        var client = new CalendarAccountClient(transport);
        var original = await client.GetAsync(Google, calendar, "display-id", "fixture-event", CancellationToken.None);
        Assert.True(original.CanEdit);
        await client.SaveAsync(Google, calendar, original with
        {
            EndDateExclusive = original.EndDateExclusive!.Value.AddDays(1),
            End = original.End.AddDays(1)
        }, original, CancellationToken.None);
        Assert.Equal(1, writes);
    }

    [Fact]
    public async Task StaleGoogleEventStopsBeforePatchAndDelete()
    {
        int reads = 0;
        var calendar = Calendar(CalendarAccountKind.Google);
        using var transport = new HttpClient(new Fixture(request =>
        {
            Assert.Equal(HttpMethod.Get, request.Method);
            return Task.FromResult(Reply(++reads == 1 ? GoogleEvent : GoogleEvent.Replace("one", "two")));
        }));
        var client = new CalendarAccountClient(transport);
        var original = await client.GetAsync(Google, calendar, "display-id", "fixture-event", CancellationToken.None);
        await Assert.ThrowsAsync<CalendarConflictException>(() => client.SaveAsync(Google, calendar,
            original with { Title = "Proposed" }, original, CancellationToken.None));
        await Assert.ThrowsAsync<CalendarConflictException>(() => client.DeleteAsync(Google, calendar, original, CancellationToken.None));
        Assert.Equal(3, reads);
    }

    [Fact]
    public async Task OutlookTitlePatchPreservesBodyLocationsAndSubMinuteTimes()
    {
        var calendar = Calendar(CalendarAccountKind.Outlook);
        int writes = 0;
        using var transport = new HttpClient(new Fixture(async request =>
        {
            Assert.Equal("graph.microsoft.com", request.RequestUri!.Host);
            Assert.EndsWith("/calendars/calendar-id/events/fixture-outlook-event", request.RequestUri.AbsolutePath);
            Assert.Contains("ImmutableId", Assert.Single(request.Headers.GetValues("Prefer")));
            if (request.Method == HttpMethod.Get) return Reply(OutlookEvent);
            Assert.Equal(HttpMethod.Patch, request.Method);
            Assert.True(Assert.Single(request.Headers.IfMatch).IsWeak);
            using var json = JsonDocument.Parse(await request.Content!.ReadAsStringAsync());
            var field = Assert.Single(json.RootElement.EnumerateObject());
            Assert.Equal("subject", field.Name);
            Assert.Equal("Updated", field.Value.GetString());
            writes++;
            return Reply(OutlookEvent);
        }));
        var client = new CalendarAccountClient(transport);
        var original = await client.GetAsync(Outlook, calendar, "display-id", "fixture-outlook-event", CancellationToken.None);
        Assert.Equal(30, original.Start.Second);
        Assert.False(original.Connected!.CanEditLocation);
        await client.SaveAsync(Outlook, calendar, original with { Title = "Updated" }, original, CancellationToken.None);
        await Assert.ThrowsAsync<InvalidOperationException>(() => client.SaveAsync(Outlook, calendar,
            original with { Location = "Replacement room" }, original, CancellationToken.None));
        Assert.Equal(1, writes);
    }

    [Fact]
    public async Task OutlookPaginationNeverForwardsTheTokenToAnotherOrigin()
    {
        int requests = 0;
        using var transport = new HttpClient(new Fixture(request =>
        {
            Assert.Equal("graph.microsoft.com", request.RequestUri!.Host);
            requests++;
            return Task.FromResult(Reply("""
                {"value":[],"@odata.nextLink":"https://elsewhere.example.test/v1.0/me/calendars?$skiptoken=fixture"}
                """));
        }));
        await Assert.ThrowsAsync<InvalidDataException>(() =>
            new CalendarAccountClient(transport).ListCalendarsAsync(Outlook, CancellationToken.None));
        Assert.Equal(1, requests);
    }

    [Fact]
    public async Task GoogleRefreshRetainsTheExistingRefreshTokenWhenOmitted()
    {
        using var transport = new HttpClient(new Fixture(async request =>
        {
            Assert.Equal("https://oauth2.googleapis.com/token", request.RequestUri!.AbsoluteUri);
            Assert.Equal(HttpMethod.Post, request.Method);
            string form = await request.Content!.ReadAsStringAsync();
            Assert.Contains("grant_type=refresh_token", form);
            Assert.Contains("refresh_token=fixture-refresh", form);
            Assert.Contains("client_secret=fixture-desktop-client", form);
            return Reply("""{"access_token":"new-access","token_type":"Bearer","expires_in":3600}""");
        }));
        var refreshed = await new CalendarAccountOAuth(transport).RefreshAsync(Google, CancellationToken.None);
        Assert.Equal("new-access", refreshed.AccessToken);
        Assert.Equal(Google.RefreshToken, refreshed.RefreshToken);
    }

    private static HttpResponseMessage Reply(string json) => new(HttpStatusCode.OK)
    { Content = new StringContent(json, Encoding.UTF8, "application/json") };

    private sealed class Fixture(Func<HttpRequestMessage, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            => send(request);
    }
}
