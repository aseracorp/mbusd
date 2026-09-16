/*
 * OpenMODBUS/TCP to RS-232/485 MODBUS RTU gateway
 *
 * mdns.c - mDNS/DNS-SD service announcement support
 *
 * The gateway is announced on the local network via multicast DNS
 * (DNS-SD, RFC 6762/6763) under the service type _modbus-tcp._tcp.
 * This lets mDNS-aware tools and home automation platforms (Home
 * Assistant, iOS, ...) discover the Modbus TCP endpoint automatically
 * without manual IP/port configuration.
 *
 * The Avahi client library is used when available (it is the mDNS
 * responder of virtually all mainstream Linux distributions). If the
 * library is not present at compile time the feature compiles to a
 * no-op and mbusd behaves exactly as before.
 *
 * Copyright (c) 2026 aseracorp
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * - Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *
 * - Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "mdns.h"

#ifdef HAVE_AVAHI
#include <avahi-client/client.h>
#include <avahi-client/publish.h>
#include <avahi-common/alternative.h>
#include <avahi-common/error.h>
#include <avahi-common/malloc.h>
#include <avahi-common/simple-watch.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "cfg.h"
#include "log.h"

/* Avahi client state (simple-watch: no external event loop integration
 * needed - announcements are sent asynchronously by the Avahi daemon and
 * the client only needs to react to state changes). */
static AvahiSimplePoll *mdns_poll = NULL;
static AvahiClient *mdns_client = NULL;
static AvahiEntryGroup *mdns_group = NULL;
static char *mdns_name = NULL;
static char *mdns_host = NULL;
static unsigned short mdns_port = 0;
static pthread_t mdns_thread;
static volatile int mdns_thread_running = 0;

static void mdns_entry_group_callback(AvahiEntryGroup *group,
                                      AvahiEntryGroupState state,
                                      void *userdata);

/* Create the service group and register the _modbus-tcp._tcp service. */
static void
mdns_create_services(AvahiClient *client)
{
  int ret;

  if (!mdns_group)
    mdns_group = avahi_entry_group_new(client, mdns_entry_group_callback, NULL);

  if (!mdns_group)
  {
    logw(0, "mdns: failed to create entry group (%s)",
         avahi_strerror(avahi_client_errno(client)));
    return;
  }

  if (avahi_entry_group_is_empty(mdns_group))
  {
    logw(2, "mdns: announcing %s on port %u (host %s)...",
         MDNS_SERVICE_TYPE, mdns_port, mdns_host ? mdns_host : "auto");

    ret = avahi_entry_group_add_service(mdns_group,
                                        AVAHI_IF_UNSPEC,
                                        AVAHI_PROTO_UNSPEC,
                                        (AvahiPublishFlags)0,
                                        mdns_name,
                                        MDNS_SERVICE_TYPE,
                                        NULL, /* domain: all */
                                        NULL, /* host: auto (resolves to
                                                 the announcing host name) */
                                        mdns_port,
                                        NULL); /* no TXT records */
    if (ret < 0)
    {
      if (ret == AVAHI_ERR_COLLISION)
      {
        /* Name collision - append a unique suffix and retry */
        char *alt = avahi_alternative_service_name(mdns_name);
        logw(1, "mdns: service name %s collision, using %s", mdns_name, alt);
        avahi_free(mdns_name);
        mdns_name = alt;
        mdns_create_services(client);
        return;
      }
      logw(0, "mdns: failed to add service (%s)",
           avahi_strerror(ret));
      return;
    }

    ret = avahi_entry_group_commit(mdns_group);
    if (ret < 0)
    {
      logw(0, "mdns: failed to commit service group (%s)",
           avahi_strerror(ret));
      return;
    }
  }
}

/* Entry group state callback - re-create services after a reset. */
static void
mdns_entry_group_callback(AvahiEntryGroup *group,
                          AvahiEntryGroupState state,
                          void *userdata)
{
  (void)userdata;

  switch (state)
  {
    case AVAHI_ENTRY_GROUP_ESTABLISHED:
      logw(2, "mdns: service successfully established");
      break;
    case AVAHI_ENTRY_GROUP_COLLISION:
      logw(1, "mdns: service name collision, retrying with new name");
      mdns_create_services(avahi_entry_group_get_client(group));
      break;
    case AVAHI_ENTRY_GROUP_FAILURE:
      logw(0, "mdns: entry group failure (%s)",
           avahi_strerror(avahi_client_errno(avahi_entry_group_get_client(group))));
      break;
    case AVAHI_ENTRY_GROUP_UNCOMMITED:
    case AVAHI_ENTRY_GROUP_REGISTERING:
      break;
  }
}

/* Client state callback - (re)start publishing once the daemon is running. */
static void
mdns_client_callback(AvahiClient *client, AvahiClientState state, void *userdata)
{
  (void)userdata;

  switch (state)
  {
    case AVAHI_CLIENT_S_RUNNING:
      if (!mdns_group)
        mdns_create_services(client);
      break;
    case AVAHI_CLIENT_S_COLLISION:
      /* Client name collision - Avahi retries automatically */
      break;
    case AVAHI_CLIENT_FAILURE:
      logw(1, "mdns: client failure (%s), reconnecting...",
           avahi_strerror(avahi_client_errno(client)));
      avahi_client_free(client);
      mdns_client = NULL;
      mdns_group = NULL;
      break;
    case AVAHI_CLIENT_S_REGISTERING:
    case AVAHI_CLIENT_CONNECTING:
      break;
  }
}

/* Avahi client event loop, run in a dedicated thread so the gateway's
 * select()-based serving loop is never blocked. */
static void *
mdns_loop(void *arg)
{
  (void)arg;
  avahi_simple_poll_loop(mdns_poll);
  mdns_thread_running = 0;
  return NULL;
}

/*
 * Start announcing the Modbus TCP endpoint via mDNS/DNS-SD.
 * name: instance name (NULL to build "<hostname>: Modbus TCP gateway"
 *       from the system host name)
 * host: host name to advertise (NULL for automatic - the Avahi daemon
 *       resolves the announcing host name to all its addresses)
 * port: TCP port of the Modbus TCP endpoint
 *
 * Return: RC_OK on success (including when Avahi is unavailable at runtime
 *         - the announcement is best-effort), RC_ERR on fatal setup errors.
 */
int
mdns_init(const char *name, const char *host, unsigned short port)
{
  int error;

  mdns_port = port;

  if (name && *name)
  {
    mdns_name = avahi_strdup(name);
  }
  else
  {
    /* Default instance name "<hostname>: Modbus TCP gateway" */
    char buf[256];
    if (gethostname(buf, sizeof(buf)) == 0)
    {
      buf[sizeof(buf) - 1] = '\0';
      size_t len = strlen(buf) + strlen(": Modbus TCP gateway") + 1;
      mdns_name = avahi_malloc(len);
      if (mdns_name)
        snprintf(mdns_name, len, "%s: Modbus TCP gateway", buf);
    }
    if (!mdns_name)
      mdns_name = avahi_strdup("mbusd: Modbus TCP gateway");
  }

  if (host && *host)
    mdns_host = avahi_strdup(host);

  mdns_poll = avahi_simple_poll_new();
  if (!mdns_poll)
  {
    logw(0, "mdns: failed to create simple poll object");
    return RC_ERR;
  }

  /* Connect to the Avahi daemon. Right after a container starts (entrypoint
   * launches dbus + avahi-daemon, then execs us) the daemon may not yet have
   * registered on the system bus, so avahi_client_new() fails with
   * AVAHI_ERR_NO_DAEMON ("Daemon not running"). Retry briefly (~6s) before
   * giving up - announcements are best-effort and must not block startup. */
  int mdns_attempt = 0;
  do
  {
    mdns_client = avahi_client_new(avahi_simple_poll_get(mdns_poll),
                                   (AvahiClientFlags)0,
                                   mdns_client_callback,
                                   NULL,
                                   &error);
    if (mdns_client || mdns_attempt >= 6)
      break;
    logw(1, "mdns: Avahi daemon not ready yet (%s), retrying... (%d/6)",
         avahi_strerror(error), mdns_attempt + 1);
    sleep(1);
    mdns_attempt++;
  } while (1);

  if (!mdns_client)
  {
    logw(1, "mdns: failed to connect to Avahi daemon (%s)",
         avahi_strerror(error));
    avahi_simple_poll_free(mdns_poll);
    mdns_poll = NULL;
    /* Not fatal: announcements simply won't happen if no responder is
     * running (e.g. in minimal containers without Avahi). */
    return RC_OK;
  }

  /* Run the Avahi client event loop in a dedicated thread. The service is
   * announced by the daemon after the client connects and registers it. */
  if (pthread_create(&mdns_thread, NULL, mdns_loop, NULL) != 0)
  {
    logw(1, "mdns: failed to start Avahi event loop thread");
    avahi_client_free(mdns_client);
    mdns_client = NULL;
    avahi_simple_poll_free(mdns_poll);
    mdns_poll = NULL;
    return RC_OK;
  }
  mdns_thread_running = 1;
  pthread_detach(mdns_thread);

  return RC_OK;
}

/* Stop announcing and free all Avahi resources. */
void
mdns_cleanup(void)
{
  if (mdns_thread_running)
  {
    avahi_simple_poll_quit(mdns_poll);
    mdns_thread_running = 0;
  }
  if (mdns_group)
  {
    avahi_entry_group_free(mdns_group);
    mdns_group = NULL;
  }
  if (mdns_client)
  {
    avahi_client_free(mdns_client);
    mdns_client = NULL;
  }
  if (mdns_poll)
  {
    avahi_simple_poll_free(mdns_poll);
    mdns_poll = NULL;
  }
  if (mdns_name)
  {
    avahi_free(mdns_name);
    mdns_name = NULL;
  }
  if (mdns_host)
  {
    avahi_free(mdns_host);
    mdns_host = NULL;
  }
}
#else /* !HAVE_AVAHI */
#include "log.h"

/*
 * mDNS support compiled out (no Avahi development library found at
 * configure time). All calls are no-ops.
 */
int
mdns_init(const char *name, const char *host, unsigned short port)
{
  (void)name;
  (void)host;
  (void)port;
  return RC_OK;
}

void
mdns_cleanup(void)
{
  /* nothing to do */
}
#endif /* HAVE_AVAHI */