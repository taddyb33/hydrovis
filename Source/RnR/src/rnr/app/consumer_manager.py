import asyncio

import aio_pika

from src.rnr.app.api.services.replace_and_route import ReplaceAndRoute
from src.rnr.app.core.cache import get_settings
from src.rnr.app.core.settings import Settings

PARALLEL_TASKS = 10


async def main(settings: Settings) -> None:
    connection = await aio_pika.connect_robust(settings.aio_pika_url)
    rnr = ReplaceAndRoute()

    async with connection:
        channel = await connection.channel()
        await channel.set_qos(prefetch_count=PARALLEL_TASKS)
        priority_queue = await channel.declare_queue(
            settings.priority_queue,
            durable=True,
        )
        base_queue = await channel.declare_queue(
            settings.base_queue,
            durable=True,
        )
        # error_queue = await channel.declare_queue(
        #     settings.error_queue,
        #     durable=True,
        # )

        print("Consumer started")

        # try:
        await priority_queue.consume(rnr.process_flood_request)
        await base_queue.consume(rnr.process_request)
        # except Exception as e:
        #     print(f"Exception thrown during message processing: {e.__str__()}")

        try:
            await asyncio.Future()
        finally:
            await connection.close()


if __name__ == "__main__":
    print("Starting consumer...")
    asyncio.run(main(get_settings()))
