# The graph

[Guide](../README.md) › Playing with it

Click an item (or search for it) and it sits in the middle. To the **right** is what it is made
from, down to raw materials. To the **left** is what it is used in.

![The graph](../media/graph.gif)

Each card shows:
- the cheapest auction price and how sure that is, then how many sell a day (`120/d`; `120+/d`
  means "at least");
- what a vendor pays, or charges if vendors stock it;
- what it costs to make, and the profit of making it.

Each card has up to three buttons: **Buy**, **Make**, **Sell**. The one to press now is lit. One
that makes no sense is grey, and hovering it says why.

The lines between cards carry the amount and its value: for your plan's quantity on the
"made from" side. Their colour says whether the step earns money: **gold** when making the next
thing pays, **grey** around nothing, **red** towards a loss. Where a step clearly earns, a faint
light drifts along its line from the material towards the thing made of it (`/cg flow` switches
the lights off).

![Lights drifting where the money flows](../media/flow.gif)

Lines are **thicker** towards the things that earn the most among those on screen, and each
line carries what one craft of the thing it leads to earns, such as `+35c/craft`.

**Moving around:** click a card to centre it, drag to pan, mouse wheel to zoom. The mouse's back
and forward buttons go back and forward.

The panel on the right belongs to the item in the middle: its prices, what a batch earns, the
price chart and the cheapest way to make it.

Next: [Opportunities](opportunities.md)
